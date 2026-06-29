# src/legacy/muninn.tcl
# Muninn legacy integration — Tcl/Tk.
# Provides two things:
#   1. An SNMP bridge: polls legacy devices via Net-SNMP's snmpget/snmpwalk
#      and normalises results into the Muninn JSON snapshot format.
#   2. A minimal Tk dashboard widget for environments where the Odin TUI
#      cannot run (headless X11 / VNC sessions on legacy infrastructure).

package require Tcl  8.6
package require json 1.3

# ─── Configuration ────────────────────────────────────────────────────────────

set cfg(snmp_community) "public"
set cfg(snmp_version)   "2c"
set cfg(targets)        {}        ;# list of IP addresses to poll
set cfg(interval_ms)    5000
set cfg(output_mode)    "json"    ;# "json" | "tk"

# Standard SNMP OIDs we care about
set oids(cpu_load_1m)   "1.3.6.1.4.1.2021.10.1.3.1"
set oids(cpu_load_5m)   "1.3.6.1.4.1.2021.10.1.3.2"
set oids(mem_total_kb)  "1.3.6.1.4.1.2021.4.5.0"
set oids(mem_free_kb)   "1.3.6.1.4.1.2021.4.11.0"
set oids(swap_total_kb) "1.3.6.1.4.1.2021.4.3.0"
set oids(swap_free_kb)  "1.3.6.1.4.1.2021.4.4.0"

# ─── SNMP helpers ─────────────────────────────────────────────────────────────

proc snmpget {host oid} {
    global cfg
    set cmd [list snmpget \
        -v $cfg(snmp_version) \
        -c $cfg(snmp_community) \
        -Oqv \
        $host $oid]
    if {[catch {exec {*}$cmd} result]} { return "" }
    string trim $result "\" \t\n"
}

proc poll_host {host} {
    global oids
    set snap {}

    dict set snap timestamp_ms [clock milliseconds]
    dict set snap source       $host

    set load1  [snmpget $host $oids(cpu_load_1m)]
    set load5  [snmpget $host $oids(cpu_load_5m)]
    set mtotal [snmpget $host $oids(mem_total_kb)]
    set mfree  [snmpget $host $oids(mem_free_kb)]
    set stotal [snmpget $host $oids(swap_total_kb)]
    set sfree  [snmpget $host $oids(swap_free_kb)]

    # Derive approximate CPU % from load (normalised to ncpu=1 assumption)
    set cpu_pct 0.0
    if {$load1 ne ""} {
        set cpu_pct [expr {min([scan $load1 %f] * 100.0, 100.0)}]
    }

    dict set snap cpu_pct  $cpu_pct
    dict set snap load [dict create one $load1 five $load5]

    if {$mtotal ne "" && $mfree ne ""} {
        dict set snap mem [dict create \
            total_kb     [expr {int($mtotal)}] \
            free_kb      [expr {int($mfree)}]  \
            available_kb [expr {int($mfree)}]  \
            swap_total_kb [expr {int($stotal)}] \
            swap_free_kb  [expr {int($sfree)}]]
    }

    return $snap
}

# ─── JSON emission ────────────────────────────────────────────────────────────

proc dict_to_json {d} {
    set parts {}
    dict for {k v} $d {
        if {[string is double -strict $v]} {
            lappend parts "\"$k\":$v"
        } elseif {[string is integer -strict $v]} {
            lappend parts "\"$k\":$v"
        } elseif {[llength $v] > 1 && [llength $v] % 2 == 0} {
            lappend parts "\"$k\":[dict_to_json $v]"
        } else {
            lappend parts "\"$k\":\"$v\""
        }
    }
    return "{[join $parts ,]}"
}

proc emit_snapshot {snap} {
    puts stdout [dict_to_json $snap]
    flush stdout
}

# ─── Tk dashboard (optional) ──────────────────────────────────────────────────

proc build_tk_dashboard {} {
    package require Tk

    wm title . "Muninn — Legacy Monitor"
    wm geometry . 600x400

    frame .header -bg #1a1a2e
    label .header.title -text "◈ MUNINN" -fg #8b5cf6 \
        -font {Helvetica 18 bold} -bg #1a1a2e
    pack .header.title -pady 8
    pack .header -fill x

    frame .metrics -bg #0f0f1a
    pack  .metrics -fill both -expand 1

    foreach {name label} {cpu "CPU %" mem "MEM %" load "LOAD"} {
        frame .metrics.$name -bg #0f0f1a
        label .metrics.$name.lbl -text $label -fg #6b7280 \
            -font {Helvetica 10} -bg #0f0f1a
        label .metrics.$name.val -text "—" -fg #e5e7eb \
            -font {Courier 24 bold} -bg #0f0f1a
        pack  .metrics.$name.lbl .metrics.$name.val
        pack  .metrics.$name -side left -expand 1 -fill both -pady 20
    }
}

proc update_tk {snap} {
    set cpu [format "%.1f%%" [dict get $snap cpu_pct]]
    set mem 0
    catch {
        set m     [dict get $snap mem]
        set total [dict get $m total_kb]
        set avail [dict get $m available_kb]
        if {$total > 0} { set mem [format "%.1f%%" [expr {($total-$avail)*100.0/$total}]] }
    }
    .metrics.cpu.val configure -text $cpu
    .metrics.mem.val configure -text $mem
}

# ─── Main loop ────────────────────────────────────────────────────────────────

proc poll_loop {} {
    global cfg
    foreach host $cfg(targets) {
        set snap [poll_host $host]
        if {$cfg(output_mode) eq "tk"} {
            update_tk $snap
        } else {
            emit_snapshot $snap
        }
    }
    after $cfg(interval_ms) poll_loop
}

# Read targets from argv
if {$argc > 0} { set cfg(targets) $argv }
if {[llength $cfg(targets)] == 0} {
    puts stderr "Usage: muninn.tcl <host1> \[host2...\] \[--tk\]"
    exit 1
}

if {"--tk" in $argv} {
    set cfg(output_mode) "tk"
    build_tk_dashboard
}

poll_loop
vwait forever
