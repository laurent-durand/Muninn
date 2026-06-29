; src/dsl/config.fnl
; Muninn config DSL — Fennel (Lisp that compiles to Lua).
; Provides a composable rule-definition language on top of Lua's runtime.
; Example:
;   (rule "cpu-spike"
;     (when (> (metric :cpu_pct) 85))
;     (for 10 :seconds)
;     (alert :crit "CPU above 85% for 10s"))

; ─── Runtime state ────────────────────────────────────────────────────────────

(local rules    [])
(local states   {})
(local handlers {})

; ─── DSL macros ───────────────────────────────────────────────────────────────

(macro rule [name & body]
  "Define an alert rule.
   Body is a sequence of (when ...) (for ...) (alert ...) clauses."
  `(let [r# {:name ,name
             :condition nil
             :duration  0
             :severity  :info
             :message   ""}]
     ,(icollect [_ clause (ipairs body)]
        (match clause
          ([:when expr]     `(tset r# :condition (fn [snap#] ,expr)))
          ([:for n unit]    `(tset r# :duration  (* ,n (match ,unit :seconds 1 :minutes 60 1))))
          ([:alert sev msg] `(do (tset r# :severity ,sev) (tset r# :message ,msg)))
          _                 nil))
     (table.insert rules r#)))

(macro metric [key]
  "Extract a metric value from the current snapshot."
  `(. _snap ,key))

(macro derived [expr]
  "Evaluate expr in the context of a snapshot, returning a number."
  `(fn [_snap] ,expr))

; ─── Built-in rule set ────────────────────────────────────────────────────────

; CPU rules
(rule "cpu-warn"
  (when (> (metric :cpu_pct) 70))
  (for 10 :seconds)
  (alert :warn "CPU utilisation above 70% for 10 seconds"))

(rule "cpu-crit"
  (when (> (metric :cpu_pct) 90))
  (for 5 :seconds)
  (alert :crit "CPU utilisation above 90% for 5 seconds"))

; Memory rules
(rule "mem-pressure"
  (when (let [m (metric :mem)]
          (and m (> (/ (- m.total_kb m.available_kb) m.total_kb) 0.90))))
  (for 5 :seconds)
  (alert :crit "Memory usage above 90%"))

; Load average spike
(rule "load-spike"
  (when (> (metric :load_one) 16))
  (for 20 :seconds)
  (alert :warn "Load average above 16 for 20 seconds"))

; Swap pressure
(rule "swap-heavy"
  (when (let [m (metric :mem)]
          (and m (> m.swap_total_kb 0)
               (> (/ (- m.swap_total_kb m.swap_free_kb) m.swap_total_kb) 0.70))))
  (for 30 :seconds)
  (alert :warn "Swap usage above 70%"))

; ─── Evaluation engine ────────────────────────────────────────────────────────

(fn evaluate-rule [rule snap now]
  (let [name  rule.name
        state (or (. states name) {:since nil :fired false})
        val?  (pcall rule.condition snap)]
    (if (and val? (rule.condition snap))
        ; condition true
        (let [since (or state.since now)
              elapsed (- now since)]
          (tset states name {:since since :fired state.fired})
          (when (and (>= elapsed rule.duration) (not state.fired))
            (tset (. states name) :fired true)
            {:name     name
             :severity rule.severity
             :message  rule.message
             :fired_at (math.floor now)}))
        ; condition false — reset
        (do (tset states name {:since nil :fired false})
            nil))))

(fn evaluate-all [snap]
  "Run all rules against `snap`, return list of fired alerts."
  (let [now     (os.time)
        alerts  []]
    (each [_ rule (ipairs rules)]
      (let [alert (evaluate-rule rule snap now)]
        (when alert (table.insert alerts alert))))
    alerts))

; ─── JSON I/O (relies on dkjson if available, else manual) ───────────────────

(local ok? (pcall require :dkjson))
(local json (if ok? (require :dkjson) nil))

(fn read-snapshot [line]
  (if json (json.decode line) nil))

(fn emit-alert [alert]
  (if json
      (print (json.encode alert))
      (print (.. "{\"name\":\"" alert.name "\",\"severity\":\"" alert.severity
                 "\",\"message\":\"" alert.message "\"}"))))

; ─── Main loop ────────────────────────────────────────────────────────────────

(fn main []
  (each [line (io.lines)]
    (let [snap (read-snapshot line)]
      (when snap
        (each [_ alert (ipairs (evaluate-all snap))]
          (emit-alert alert))))))

(main)
