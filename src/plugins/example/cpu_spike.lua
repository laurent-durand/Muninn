-- src/plugins/example/cpu_spike.lua
-- Example Muninn plugin: sustained CPU spike detector with rate-of-change.

local SPIKE_THRESHOLD = 85.0
local SPIKE_DURATION  = 5      -- seconds before firing
local COOLDOWN        = 30     -- seconds after resolution before re-arming

local state = {
  above_since  = nil,
  last_fire    = nil,
  history      = {},  -- ring buffer of last 60 cpu_pct values
  history_head = 0,
}

local function ring_push(v)
  state.history_head = (state.history_head % 60) + 1
  state.history[state.history_head] = v
end

local function ring_avg()
  local sum, n = 0, 0
  for _, v in ipairs(state.history) do
    sum = sum + v
    n   = n + 1
  end
  return n > 0 and sum / n or 0
end

-- ─── Plugin table (returned to host) ─────────────────────────────────────────

return {
  name    = "cpu-spike-detector",
  version = "0.1.0",

  on_init = function()
    print("cpu-spike-detector: armed (threshold=" ..
          SPIKE_THRESHOLD .. "%, duration=" .. SPIKE_DURATION .. "s)")
  end,

  on_snapshot = function(snap)
    local cpu = snap.cpu_pct or 0
    local now = os.time()

    ring_push(cpu)

    if cpu >= SPIKE_THRESHOLD then
      if not state.above_since then
        state.above_since = now
      end
      local elapsed = now - state.above_since
      local cooled  = not state.last_fire or (now - state.last_fire) >= COOLDOWN

      if elapsed >= SPIKE_DURATION and cooled then
        local avg = ring_avg()
        emit_alert("warn",
          string.format("CPU spike: %.1f%% (60s avg %.1f%%) sustained %ds",
                        cpu, avg, elapsed),
          { metric = "cpu_pct", value = tostring(cpu) })
        state.last_fire = now
      end
    else
      state.above_since = nil
    end
  end,

  on_shutdown = function()
    print("cpu-spike-detector: shutting down")
  end,
}
