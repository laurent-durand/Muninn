# src/script/dashboard.janet
# Muninn dashboard scripting — Janet (lisp dialect, embeds in C).
# This script is loaded by the TUI at startup and can be hot-reloaded.
# It defines:
#   (on-snapshot snap)  — called every second with the latest metrics
#   (on-alert alert)    — called when muninn-rules emits an alert
#   (panel-layout)      — returns the panel arrangement for the TUI

# ─── Utility ──────────────────────────────────────────────────────────────────

(defn pct-bar
  "Render a text progress bar of `width` chars for a value 0–100."
  [value width]
  (let [filled (math/round (* (/ (min value 100) 100) width))
        empty  (- width filled)]
    (string
      (string/repeat "█" filled)
      (string/repeat "░" empty))))

(defn severity-color
  "Return an ANSI colour code based on severity (warn/crit thresholds)."
  [value warn crit]
  (cond
    (>= value crit)  "\x1b[31m"   # red
    (>= value warn)  "\x1b[33m"   # yellow
    true             "\x1b[32m")) # green

(defn human-bytes
  "Format a byte count as a human-readable string."
  [n]
  (cond
    (>= n (math/pow 2 30)) (string/format "%.1fGiB" (/ n (math/pow 2 30)))
    (>= n (math/pow 2 20)) (string/format "%.1fMiB" (/ n (math/pow 2 20)))
    (>= n (math/pow 2 10)) (string/format "%.1fKiB" (/ n (math/pow 2 10)))
    true                   (string/format "%dB" n)))

# ─── Alert history ring buffer ────────────────────────────────────────────────

(def alert-history (array/new 100))

(defn push-alert! [alert]
  (array/push alert-history alert)
  (when (> (length alert-history) 100)
    (array/remove alert-history 0)))

# ─── Callbacks (called from C host via janet_call) ───────────────────────────

(defn on-snapshot
  "Process a decoded snapshot table. Called every poll interval."
  [snap]
  (let [cpu  (get snap :cpu_pct 0)
        mem  (get snap :mem {})
        load (get snap :load {})]
    # Return a table the TUI C code can inspect
    @{:cpu_bar   (pct-bar cpu 40)
      :cpu_color (severity-color cpu 70 90)
      :cpu_pct   cpu
      :mem_used  (- (get mem :total_kb 0) (get mem :available_kb 0))
      :mem_total (get mem :total_kb 0)
      :load_1    (get load :one 0)
      :load_5    (get load :five 0)
      :load_15   (get load :fifteen 0)
      :alerts    alert-history}))

(defn on-alert
  "Handle an incoming alert. Push to history, return formatted string."
  [alert]
  (push-alert! alert)
  (let [sev  (get alert :severity "info")
        msg  (get alert :message "")
        col  (case sev
               "crit" "\x1b[31m"
               "warn" "\x1b[33m"
               "\x1b[36m")]
    (string col "[" sev "] " msg "\x1b[0m")))

# ─── Panel layout DSL ─────────────────────────────────────────────────────────

(defn panel-layout
  "Describe the TUI panel arrangement.
   The C TUI reads this to know which widgets to render and where."
  []
  @[# Row 1: CPU full-width
    @{:id :cpu    :row 0 :col 0 :width 1.0 :height 0.2}
    # Row 2: Memory | Swap side by side
    @{:id :mem    :row 1 :col 0 :width 0.5 :height 0.15}
    @{:id :swap   :row 1 :col 1 :width 0.5 :height 0.15}
    # Row 3: Network full-width
    @{:id :net    :row 2 :col 0 :width 1.0 :height 0.25}
    # Row 4: Process list | Alerts
    @{:id :procs  :row 3 :col 0 :width 0.65 :height 0.3}
    @{:id :alerts :row 3 :col 1 :width 0.35 :height 0.3}
    # Row 5: Sparkline history
    @{:id :spark  :row 4 :col 0 :width 1.0 :height 0.1}])

# ─── Custom metric transforms ─────────────────────────────────────────────────

(defn cpu-pressure-score
  "Combine CPU%, load average and iowait into a single pressure index 0–100."
  [snap]
  (let [cpu    (get snap :cpu_pct 0)
        load1  (get-in snap [:load :one] 0)
        nproc  (max 1 (get snap :cpu_cores 1))
        load-n (min (* (/ load1 nproc) 100) 100)]
    (math/round (/ (+ (* 0.6 cpu) (* 0.4 load-n)) 1))))

(defn net-total-bps
  "Sum rx+tx bps across all interfaces."
  [snap]
  (reduce + 0
    (map (fn [iface]
           (+ (get iface :rx_bps 0)
              (get iface :tx_bps 0)))
         (get snap :net []))))
