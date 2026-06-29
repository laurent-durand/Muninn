# src/array/transforms.bqn
# Muninn metric transforms — BQN.
# BQN's array primitives make rolling window stats, normalisation,
# and anomaly scoring extremely concise.
# This script reads a stream of CPU % values (one per line) and emits
# a JSON summary after each window fills.

# ─── Window operations ────────────────────────────────────────────────────────

# Moving average over window W
MovAvg ← {w 𝕊 xs:
  n ← ≠xs
  w ↑ n  # clamp window to available data
  (+´ ∘ (w↑·⌽)¨ ↕n) ÷ w
}

# Standard deviation
StdDev ← {xs:
  n ← ≠xs
  μ ← (+´xs) ÷ n
  √ (+´(xs-μ)⋆2) ÷ n
}

# Z-score normalisation
ZNorm ← {xs:
  μ ← (+´xs) ÷ ≠xs
  σ ← StdDev xs
  (xs - μ) ÷ σ + 1e-9  # avoid ÷0
}

# Percentile (linear interpolation)
Pct ← {p 𝕊 xs:
  sorted ← ∧xs
  n      ← ≠sorted
  i_f    ← p × (n-1) ÷ 100
  lo     ← ⌊i_f
  hi     ← ⌈i_f
  frac   ← i_f - lo
  ((1-frac) × lo⊑sorted) + frac × hi⊑sorted
}

# Detect spikes: values more than k σ above the mean
Spikes ← {k 𝕊 xs:
  μ ← (+´xs) ÷ ≠xs
  σ ← StdDev xs
  (xs > μ + k×σ) / ↕≠xs   # indices of spike positions
}

# Ewma: exponentially weighted moving average, decay α
Ewma ← {α 𝕊 xs:
  (⊢ ∾ {(α×⊢) + (1-α)×⊣}´)⌾⌽ xs
}

# ─── Report assembly ──────────────────────────────────────────────────────────

FormatReport ← {xs:
  n    ← ≠xs
  μ    ← (+´xs) ÷ n
  σ    ← StdDev xs
  p50  ← 50 Pct xs
  p90  ← 90 Pct xs
  p99  ← 99 Pct xs
  sp   ← Spikes 2.5 𝕊 xs   # 2.5σ spikes
  ewma ← ⊣´ 0.1 Ewma xs    # latest ewma value

  # Return as a flat list of key-value pairs (caller formats JSON)
  ⟨"n"‿n, "mean"‿μ, "stddev"‿σ,
   "p50"‿p50, "p90"‿p90, "p99"‿p99,
   "spike_count"‿(≠sp), "ewma"‿ewma⟩
}

# ─── I/O loop ─────────────────────────────────────────────────────────────────

WINDOW ← 60

ReadLines ← {
  lines ← •file.Lines "-"    # read stdin
  lines •ParseFloat¨ lines
}

Main ← {
  values ← ReadLines@
  n      ← ≠values

  # Process in WINDOW-sized chunks
  chunks ← (⌈n÷WINDOW) ⥊ WINDOW
  0 {start:
    win    ← start ↓ WINDOW ↑ values
    report ← FormatReport win
    # Emit minimal JSON
    •Out "{""window_start"":"∾(•Fmt start)∾",""stats"":{"
    {pair: •Out (⊑pair)∾":"∾•Fmt (1⊑pair)∾","} ¨ report
    •Out "}}"
    start + WINDOW
  }´ ↕(⌈n÷WINDOW)
}

Main@
