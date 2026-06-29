// src/fanout/src/fanout.gleam
// Muninn fan-out — Gleam on Erlang/OTP.
// Receives metric snapshots via stdin (one JSON per line),
// distributes them concurrently to a registry of subscriber processes.
// Each subscriber is a lightweight BEAM process — thousands are fine.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/supervisor
import gleam/io
import gleam/json
import gleam/dynamic.{type Dynamic}
import gleam/result
import gleam/list
import gleam/dict.{type Dict}
import gleam/string
import gleam/int

// ─── Messages ─────────────────────────────────────────────────────────────────

pub type FanoutMsg {
  Publish(payload: String)
  Subscribe(id: String, pid: Subject(String))
  Unsubscribe(id: String)
  Shutdown
}

// ─── Fan-out actor ────────────────────────────────────────────────────────────

pub type FanoutState {
  FanoutState(subscribers: Dict(String, Subject(String)))
}

pub fn fanout_loop(
  msg: FanoutMsg,
  state: FanoutState,
) -> actor.Next(FanoutMsg, FanoutState) {
  case msg {
    Publish(payload) -> {
      // Send to all subscribers concurrently (non-blocking cast)
      dict.each(state.subscribers, fn(_, sub) {
        process.send(sub, payload)
      })
      actor.continue(state)
    }

    Subscribe(id, pid) -> {
      io.println("fanout: subscriber joined id=" <> id)
      let new_subs = dict.insert(state.subscribers, id, pid)
      actor.continue(FanoutState(new_subs))
    }

    Unsubscribe(id) -> {
      io.println("fanout: subscriber left id=" <> id)
      let new_subs = dict.delete(state.subscribers, id)
      actor.continue(FanoutState(new_subs))
    }

    Shutdown -> actor.Stop(process.Normal)
  }
}

pub fn start_fanout() -> Result(Subject(FanoutMsg), actor.StartError) {
  actor.start(FanoutState(dict.new()), fanout_loop)
}

// ─── Metric decoder (partial) ─────────────────────────────────────────────────

pub type Snapshot {
  Snapshot(
    timestamp_ms: Int,
    cpu_pct:      Float,
  )
}

fn decode_snapshot(raw: String) -> Result(Snapshot, json.DecodeError) {
  let decoder =
    dynamic.decode2(
      Snapshot,
      dynamic.field("timestamp_ms", dynamic.int),
      dynamic.field("cpu_pct",      dynamic.float),
    )
  json.decode(raw, decoder)
}

// ─── Stdin reader ─────────────────────────────────────────────────────────────

fn read_stdin_loop(fanout: Subject(FanoutMsg)) -> Nil {
  case io.get_line("") {
    Ok(line) -> {
      let trimmed = string.trim(line)
      case string.length(trimmed) > 0 {
        True  -> process.send(fanout, Publish(trimmed))
        False -> Nil
      }
      read_stdin_loop(fanout)
    }
    Error(_) -> {
      io.println("fanout: stdin closed, shutting down")
      process.send(fanout, Shutdown)
    }
  }
}

// ─── Demo subscriber ─────────────────────────────────────────────────────────

fn start_logger_subscriber(
  fanout: Subject(FanoutMsg),
  id: String,
) -> Subject(String) {
  let sub_subject = process.new_subject()
  process.start(fn() {
    let rec loop = fn() {
      case process.receive(sub_subject, 5000) {
        Ok(payload) -> {
          case decode_snapshot(payload) {
            Ok(snap) ->
              io.println(
                "[" <> id <> "] cpu=" <>
                float_to_string(snap.cpu_pct) <> "%"
              )
            Error(_) -> Nil
          }
          loop()
        }
        Error(_) -> loop()
      }
    }
    loop()
  }, True)
  process.send(fanout, Subscribe(id, sub_subject))
  sub_subject
}

fn float_to_string(f: Float) -> String {
  // Gleam doesn't have stdlib float→string with precision yet; placeholder
  int.to_string(float.round(f))
}

// ─── Main ─────────────────────────────────────────────────────────────────────

pub fn main() {
  case start_fanout() {
    Ok(fanout) -> {
      // Spin up a few demo subscribers
      start_logger_subscriber(fanout, "logger-1")
      start_logger_subscriber(fanout, "logger-2")

      // Read stdin in main process
      read_stdin_loop(fanout)
    }
    Error(e) -> {
      io.println("Failed to start fanout actor")
    }
  }
}
