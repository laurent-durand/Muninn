# src/config/heartbeat.nim
# Writes a heartbeat file to /run/muninn/<component>.hb every second.
# The Ada watchdog reads modification timestamps to detect dead processes.

import std/[os, times, strformat, posix]

const HB_DIR = "/run/muninn"

proc writeHeartbeat*(component: string) =
  ## Touch /run/muninn/<component>.hb to signal liveness.
  let path = &"{HB_DIR}/{component}.hb"
  try:
    writeFile(path, $epochTime())
  except IOError:
    # Dir might not exist yet — create it and retry
    createDir(HB_DIR)
    try:
      writeFile(path, $epochTime())
    except:
      discard

proc heartbeatLoop*(component: string) {.noreturn.} =
  ## Run forever, writing heartbeat every 1s.
  ## Call from a separate thread.
  while true:
    writeHeartbeat(component)
    sleep(1_000)

when isMainModule:
  let comp = if paramCount() > 0: paramStr(1) else: "config"
  echo &"heartbeat: writing to {HB_DIR}/{comp}.hb"
  heartbeatLoop(comp)
