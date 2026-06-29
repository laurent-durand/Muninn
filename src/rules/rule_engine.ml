(* src/rules/rule_engine.ml
   Muninn alert rule engine.
   Reads metric snapshots from stdin (JSON lines published by the Go broker),
   evaluates a set of composable rules, and emits Alert JSON to stdout.

   Rules are expressed as a small algebraic DSL:
     Threshold  — fires when a scalar metric crosses a boundary
     Rate       — fires on derivative (Δv/Δt)
     Composite  — AND / OR of sub-rules
     Inhibit    — suppresses a rule while another is firing
*)

module Json = Yojson.Safe

(* ─── DSL ────────────────────────────────────────────────────────────────── *)

type severity = Info | Warn | Crit [@@deriving show]

type expr =
  | Metric of string                          (* leaf: lookup metric by dot-path *)
  | Const  of float
  | Add    of expr * expr
  | Sub    of expr * expr
  | Mul    of expr * expr
  | Div    of expr * expr

type cmp = Gt | Lt | Gte | Lte | Eq

type rule = {
  name      : string;
  expr      : expr;
  cmp       : cmp;
  threshold : float;
  severity  : severity;
  for_secs  : float;           (* must hold for this duration before firing *)
}

type composite =
  | Leaf    of rule
  | All     of composite list  (* fires when all children fire *)
  | Any     of composite list  (* fires when any child fires  *)
  | Inhibit of composite * composite  (* Inhibit(signal, suppressor) *)

(* ─── Evaluation context ─────────────────────────────────────────────────── *)

type snapshot = {
  ts_ms  : int64;
  fields : (string * float) list;
}

let lookup snap path =
  List.assoc_opt path snap.fields

let eval_expr snap expr =
  let rec go = function
    | Metric p -> (match lookup snap p with Some v -> v | None -> nan)
    | Const  v -> v
    | Add (a, b) -> go a +. go b
    | Sub (a, b) -> go a -. go b
    | Mul (a, b) -> go a *. go b
    | Div (a, b) -> let b' = go b in if b' = 0.0 then nan else go a /. b'
  in go expr

let eval_cmp cmp v threshold =
  match cmp with
  | Gt  -> v >  threshold
  | Lt  -> v <  threshold
  | Gte -> v >= threshold
  | Lte -> v <= threshold
  | Eq  -> abs_float (v -. threshold) < 1e-9

(* ─── State machine ─────────────────────────────────────────────────────── *)

type rule_state = {
  pending_since : float option;  (* epoch when condition first became true *)
  firing        : bool;
}

let empty_state = { pending_since = None; firing = false }

(* Returns (new_state, should_fire) *)
let tick_rule rule state snap now =
  let v    = eval_expr snap rule.expr in
  let cond = (not (Float.is_nan v)) && eval_cmp rule.cmp v rule.threshold in
  if cond then
    let since = match state.pending_since with
      | Some t -> t
      | None   -> now
    in
    let elapsed = now -. since in
    let firing  = elapsed >= rule.for_secs in
    ({ pending_since = Some since; firing }, firing && not state.firing)
  else
    ({ pending_since = None; firing = false }, false)

(* ─── Built-in rule set ──────────────────────────────────────────────────── *)

let default_rules = [
  { name = "cpu_high_warn"; expr = Metric "cpu_pct";
    cmp = Gte; threshold = 70.0; severity = Warn; for_secs = 10.0 };
  { name = "cpu_high_crit"; expr = Metric "cpu_pct";
    cmp = Gte; threshold = 90.0; severity = Crit; for_secs =  5.0 };
  { name = "mem_pressure";
    expr = Div (Sub (Metric "mem.total_kb", Metric "mem.available_kb"),
                Metric "mem.total_kb");
    cmp = Gte; threshold = 0.90; severity = Crit; for_secs = 5.0 };
  { name = "swap_active";
    expr = Div (Sub (Metric "mem.swap_total_kb", Metric "mem.swap_free_kb"),
                Metric "mem.swap_total_kb");
    cmp = Gte; threshold = 0.50; severity = Warn; for_secs = 15.0 };
  { name = "load_spike";
    expr = Metric "load.one";
    cmp = Gte; threshold = 8.0; severity = Warn; for_secs = 10.0 };
]

(* ─── JSON parsing ───────────────────────────────────────────────────────── *)

let float_of_json j =
  match j with
  | `Float f -> f
  | `Int   i -> float_of_int i
  | _        -> nan

(* Flatten a JSON object into a dot-path → float association list *)
let rec flatten prefix j acc =
  match j with
  | `Assoc kvs ->
    List.fold_left (fun a (k, v) ->
      let p = if prefix = "" then k else prefix ^ "." ^ k in
      flatten p v a
    ) acc kvs
  | `Float _ | `Int _ ->
    (prefix, float_of_json j) :: acc
  | _ -> acc

let parse_snapshot line =
  match Json.from_string line with
  | exception _ -> None
  | j ->
    let ts_ms  = match j |> Json.Util.member "timestamp_ms" with
      | `Int i  -> Int64.of_int i
      | `Float f -> Int64.of_float f
      | _ -> 0L
    in
    let fields = flatten "" j [] in
    Some { ts_ms; fields }

(* ─── Alert emission ─────────────────────────────────────────────────────── *)

let emit_alert rule value ts_ms =
  let j = `Assoc [
    "rule_name", `String rule.name;
    "severity",  `String (show_severity rule.severity);
    "message",   `String (Printf.sprintf "%s crossed %.2f (value=%.2f)"
                            rule.name rule.threshold value);
    "fired_at",  `Int (Int64.to_int ts_ms);
    "value",     `Float value;
  ] in
  print_string (Json.to_string j);
  print_newline ();
  flush stdout

(* ─── Main loop ──────────────────────────────────────────────────────────── *)

let () =
  let states = Hashtbl.create 16 in
  List.iter (fun r -> Hashtbl.replace states r.name empty_state) default_rules;

  try while true do
    let line = input_line stdin in
    match parse_snapshot line with
    | None -> ()
    | Some snap ->
      let now = Int64.to_float snap.ts_ms /. 1000.0 in
      List.iter (fun rule ->
        let st = Hashtbl.find_opt states rule.name
                 |> Option.value ~default:empty_state in
        let v  = eval_expr snap rule.expr in
        let (st', fire) = tick_rule rule st snap now in
        Hashtbl.replace states rule.name st';
        if fire then emit_alert rule v snap.ts_ms
      ) default_rules
  done
  with End_of_file -> ()
