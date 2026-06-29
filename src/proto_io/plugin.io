// src/proto_io/plugin.io
// Muninn plugin scripting — Io.
// Io's prototype model lets plugins inherit and override behaviour with
// zero boilerplate. Each plugin is a clone of the base Plugin prototype.

// ─── Plugin prototype ─────────────────────────────────────────────────────────

Plugin := Object clone do(
    name      := "unnamed-plugin"
    version   := "0.0.1"
    enabled   := true

    // Lifecycle hooks — override in clones
    onInit     := method(
        "Plugin loaded: " .. name println
    )

    onSnapshot := method(snap,
        // Default: do nothing
        nil
    )

    onAlert    := method(alert,
        ("[alert] " .. alert at("severity") .. ": " .. alert at("message")) println
    )

    onShutdown := method(
        "Plugin unloaded: " .. name println
    )

    // Helpers available to all plugins
    emitAlert  := method(severity, message, value,
        alert := Map clone
        alert atPut("type",     "alert")
        alert atPut("severity", severity)
        alert atPut("message",  message)
        alert atPut("value",    value asString)
        alert atPut("ts",       Date now asNumber asString)
        alert asJSON println
    )

    emitMetric := method(name, value, tags,
        m := Map clone
        m atPut("type",  "custom_metric")
        m atPut("name",  name)
        m atPut("value", value asString)
        m atPut("tags",  tags)
        m asJSON println
    )
)

// ─── Built-in plugins ─────────────────────────────────────────────────────────

CpuMonitor := Plugin clone do(
    name      := "cpu-monitor"
    version   := "0.1.0"
    threshold := 85.0
    history   := List clone
    maxHist   := 60

    onInit    := method(
        ("CpuMonitor armed, threshold=" .. threshold asString .. "%") println
    )

    onSnapshot := method(snap,
        cpu := snap at("cpu_pct") asNumber
        history append(cpu)
        history size > maxHist ifTrue(history removeFirst)

        cpu >= threshold ifTrue(
            // Calculate how many consecutive samples are above threshold
            streak := 0
            history reverseDo(v,
                v >= threshold ifTrue(streak = streak + 1) ifFalse(return)
            )
            streak >= 5 ifTrue(
                emitAlert("warn",
                    "CPU above " .. threshold asString .. "% for " .. streak asString .. "s",
                    cpu)
            )
        )
    )
)

MemMonitor := Plugin clone do(
    name := "mem-monitor"

    onSnapshot := method(snap,
        mem := snap at("mem")
        mem ifNil(return)
        total := mem at("total_kb") asNumber
        avail := mem at("available_kb") asNumber
        total > 0 ifTrue(
            pct := (total - avail) / total * 100
            pct >= 90 ifTrue(
                emitAlert("crit",
                    "Memory at " .. pct round asString .. "% — above 90%",
                    pct)
            )
        )
    )
)

LoadMonitor := Plugin clone do(
    name := "load-monitor"

    onSnapshot := method(snap,
        load := snap at("load")
        load ifNil(return)
        l1 := load at("one") asNumber
        l1 >= 8.0 ifTrue(
            emitAlert("warn",
                "Load average " .. l1 asString .. " >= 8.0",
                l1)
        )
    )
)

// ─── Plugin host ──────────────────────────────────────────────────────────────

PluginHost := Object clone do(
    plugins := List with(CpuMonitor, MemMonitor, LoadMonitor)

    init := method(
        plugins foreach(p, p onInit)
    )

    dispatch := method(snap,
        plugins foreach(p,
            p enabled ifTrue(
                e := try(p onSnapshot(snap))
                e catch(Exception,
                    ("Plugin " .. p name .. " error: " .. e message) println
                )
            )
        )
    )

    shutdown := method(
        plugins foreach(p, p onShutdown)
    )
)

// ─── Main loop ────────────────────────────────────────────────────────────────

host := PluginHost clone
host init

line := File standardInput readLine
while(line != nil,
    snap := line parseJSON
    snap ifNil(
        line = File standardInput readLine
        continue
    )
    host dispatch(snap)
    line = File standardInput readLine
)

host shutdown
