# src/array/uiua_metrics.ua
# Muninn metric processing — Uiua.
# Uiua's stack-based array model lets us express rolling statistics,
# anomaly detection and threshold evaluation as pure point-free pipelines.

# ─── Constants ────────────────────────────────────────────────────────────────

WarnCpu  ← 70
CritCpu  ← 90
WarnMem  ← 80
CritMem  ← 95
Window   ← 60     # rolling window size

# ─── Array utilities ──────────────────────────────────────────────────────────

# Clamp a value between lo and hi
Clamp ← ⊙⊙(↧) ↥

# Mean of an array
Mean ← ÷⊃(/ +)(⧻)

# Population standard deviation
Stddev ← √ Mean ⊸(- Mean) ⊸ × .

# Z-score of each element
Zscore ← ÷ ⊙Stddev ⊸(- Mean)

# nth percentile (linear interp on sorted array)
Pct ← (
  # stack: percentile array
  ⊙(⊏⍏.)    # sort array, keep percentile
  # interp index
  ⊙⋅(⧻.)    # length of sorted
  ⊙⊙(- 1)   # n-1
  ⊙× ÷ 100  # (p/100)*(n-1) = float index
  ⊙⊙⌊ .     # lo = floor(idx)
  ⊙⊙⊙⌈ .    # hi = ceil(idx)
  # linear interpolation: sorted[lo]*(1-frac) + sorted[hi]*frac
  ⊙⊙⊙(⊢)    # grab hi element
  ⊙⊙(⊢)     # grab lo element
  ⊙(- ⌊.)   # frac = idx - floor(idx)
  + ⊙× ⊙⊙(× - 1 .)
)

# Ewma with decay alpha — result is array of ewma values
Ewma ← (
  # stack: alpha xs
  ⊙(⊢ ↙ 1)            # first element as initial state
  ∧(⊙⊙(+ × ⊙⊙.) ⊸.)  # fold: ewma = alpha*x + (1-alpha)*prev
)

# ─── Spike detection ──────────────────────────────────────────────────────────

# Return mask: 1 where value is more than k*stddev above mean
SpikeMask ← (
  # stack: k xs
  ⊙. Mean . Stddev
  # threshold = mean + k*stddev
  + × ⊙⊙.
  # mask = xs > threshold
  < ⊙⊙.
)

# ─── Threshold evaluation ─────────────────────────────────────────────────────

# Given value and (warn crit) thresholds, return severity 0=ok 1=warn 2=crit
Severity ← (
  ≥ ⊙(≥ ⊙(0)) ⊸.   # crit check, warn check, base 0
  + .                # 0 + warn_flag + crit_flag → 0|1|2
  ⊙(⊢)
)

# ─── Window statistics report ─────────────────────────────────────────────────

WindowReport ← (
  # stack: xs (last Window elements)
  ⊙⊙⊙⊙⊙(⧻)                     # n
  ⊙⊙⊙⊙(Mean .)                  # mean
  ⊙⊙⊙(Stddev .)                 # stddev
  ⊙⊙(50 Pct .)                  # p50
  ⊙(90 Pct .)                   # p90
  99 Pct .                       # p99
  # assemble result array: [n mean std p50 p90 p99]
  [⊙⊙⊙⊙⊙◌]
)

# ─── Entry point ──────────────────────────────────────────────────────────────

# Read CPU percentages from stdin, one per line, emit reports every Window lines
Main ← (
  &rs "\n" &sc 0         # read all stdin, split on newlines
  ⊜(parse) ≠ @\0 .       # parse non-null tokens to floats
  ⌈ ÷ Window ⧻ .         # number of full+partial windows
  ↯ ⊙Window .            # reshape into (n_windows × Window) matrix
  ≡WindowReport           # apply report to each row
  ≡(
    &p /"cpu_window_report: n="
    ⊙⊙⊙⊙⊙(⊢ . &p)        # print n
    ⊙⊙⊙⊙(⊢ . &p)         # print mean
    # etc. — full JSON formatting elided for brevity
  )
)

Main
