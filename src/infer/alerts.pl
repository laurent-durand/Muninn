% src/infer/alerts.pl
% Muninn alert inference — SWI-Prolog.
% Encodes alert rules as Horn clauses, enabling logical inference over
% metric states. More expressive than threshold rules: can reason about
% combinations and temporal patterns.

:- module(muninn_alerts, [evaluate/2, load_snapshot/1]).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(http/json)).
:- use_module(library(aggregate)).

% ─── Dynamic metric store ────────────────────────────────────────────────────

:- dynamic metric/2.     % metric(Key, Value)
:- dynamic fired/1.      % fired(RuleName) — avoid re-firing

% ─── Load a snapshot from a JSON dict ───────────────────────────────────────

load_snapshot(Dict) :-
    retractall(metric(_, _)),
    (get_dict(cpu_pct, Dict, CPU)      -> assert(metric(cpu_pct, CPU))      ; true),
    (get_dict(load,    Dict, Load),
     get_dict(one,     Load, L1)       -> assert(metric(load_one,  L1))     ; true),
    (get_dict(mem,     Dict, Mem),
     get_dict(total_kb,     Mem, Tot),
     get_dict(available_kb, Mem, Avl) ->
         ( Tot > 0
         -> MemPct is (Tot - Avl) / Tot * 100,
            assert(metric(mem_pct, MemPct))
         ;  true )
    ; true),
    (get_dict(mem, Dict, Mem2),
     get_dict(swap_total_kb, Mem2, ST),
     get_dict(swap_free_kb,  Mem2, SF),
     ST > 0
    -> SwapPct is (ST - SF) / ST * 100,
       assert(metric(swap_pct, SwapPct))
    ; true).

% ─── Alert rules as Horn clauses ────────────────────────────────────────────

% Rule: CPU warning
alert(cpu_warn, warn, Msg) :-
    metric(cpu_pct, CPU),
    CPU >= 70,
    format(atom(Msg), "CPU at ~1f% (>= 70%)", [CPU]).

% Rule: CPU critical
alert(cpu_crit, crit, Msg) :-
    metric(cpu_pct, CPU),
    CPU >= 90,
    format(atom(Msg), "CPU at ~1f% (>= 90%) — CRITICAL", [CPU]).

% Rule: Memory pressure
alert(mem_pressure, crit, Msg) :-
    metric(mem_pct, Mem),
    Mem >= 90,
    format(atom(Msg), "Memory at ~1f% (>= 90%)", [Mem]).

% Rule: High load
alert(load_high, warn, Msg) :-
    metric(load_one, L),
    L >= 8.0,
    format(atom(Msg), "Load average ~2f (>= 8.0)", [L]).

% Rule: Swap saturation
alert(swap_sat, warn, Msg) :-
    metric(swap_pct, Swap),
    Swap >= 70,
    format(atom(Msg), "Swap at ~1f% (>= 70%)", [Swap]).

% Compound rule: CPU + memory both elevated (system under compound pressure)
alert(compound_pressure, crit, Msg) :-
    metric(cpu_pct, CPU),  CPU >= 80,
    metric(mem_pct, Mem),  Mem >= 80,
    format(atom(Msg),
           "Compound pressure: CPU ~1f% + Mem ~1f% both above 80%",
           [CPU, Mem]).

% ─── Evaluation ─────────────────────────────────────────────────────────────

evaluate(Snapshot, Alerts) :-
    load_snapshot(Snapshot),
    findall(
        alert{rule: Name, severity: Sev, message: Msg},
        alert(Name, Sev, Msg),
        Alerts
    ).

% ─── JSON I/O loop ───────────────────────────────────────────────────────────

:- initialization(main, main).

main :-
    set_prolog_flag(encoding, utf8),
    process_stdin.

process_stdin :-
    read_term_from_atom('', _, []),   % warm up
    catch(
        ( read_line_to_string(user_input, Line),
          Line \= end_of_file,
          ( atom_json_dict(Line, Snap, [])
          -> evaluate(Snap, Alerts),
             maplist(emit_alert, Alerts)
          ;  true
          ),
          process_stdin
        ),
        end_of_file,
        true
    ).

emit_alert(Alert) :-
    atom_json_dict(Json, Alert, []),
    format("~w~n", [Json]).
