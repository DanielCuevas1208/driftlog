//// The Driftlog demo.
////
//// Run it with `gleam run`. It starts a sync server, lets two replicas edit
//// the same document offline, and shows them converge through the server.
////
////  - `gleam run`                run the socket demo
////  - `gleam run -- replay FILE` replay a fixture file
////  - `gleam run -- server PORT` run a standalone sync server

import driftlog/sync/net
import driftlog/sync/peer.{
  type PeerMessage, type PeerSnapshot, add_set, edit_delete, edit_insert,
  remove_set, set_register, snapshot, stop, sync,
}
import driftlog/sync/scenario.{
  type Scenario, EditAdd, EditDelete, EditInsert, EditRemove, EditSetRegister,
  Replica, Scenario, decode as decode_scenario,
}
import driftlog/sync/server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/set
import gleam/string

const host = "127.0.0.1"

const demo_version = "0.3.0"

/// A started peer actor and its replica name.
type ConnectedPeer {
  ConnectedPeer(name: String, subject: process.Subject(PeerMessage))
}

pub fn main() {
  let args = net.argv()
  case args {
    [] -> run(demo_scenario())
    ["replay", path] -> replay(path)
    ["server", port] -> server_mode(int.parse(port))
    _ -> usage()
  }
}

fn run(scenario: Scenario) {
  print_banner(scenario.title)
  case server.start(0) {
    Ok(#(server_subject, port)) -> {
      let outcome = play(scenario, port)
      server.stop(server_subject)
      case outcome {
        Ok(result) -> io.println(result)
        Error(reason) -> io.println("Demo failed: " <> reason)
      }
    }
    Error(reason) -> io.println("Could not start server: " <> reason)
  }
}

fn play(scenario: Scenario, port: Int) -> Result(String, String) {
  use peers <- result.try(connect_peers(scenario, port))
  let _ = seed_base(scenario, peers)
  let _ = edit_offline(scenario, peers)
  let _ = sync_until_settled(peers)
  let outcome = final_report(scenario, peers)
  list.each(peers, fn(peer) { stop(peer.subject) })
  outcome
}

fn connect_peers(
  scenario: Scenario,
  port: Int,
) -> Result(List(ConnectedPeer), String) {
  let attempts =
    list.map(scenario.replicas, fn(replica) {
      peer.start(replica.name, host, port)
      |> result.map(fn(subject) { ConnectedPeer(name: replica.name, subject:) })
    })
  result.all(attempts)
}

fn seed_base(scenario: Scenario, peers: List(ConnectedPeer)) -> Nil {
  io.println("")
  io.println("1. Shared base document")
  io.println("-----------------------")
  case list.first(peers) {
    Ok(first) -> {
      let _ = edit_insert(first.subject, 0, scenario.base)
      io.println(first.name <> " types " <> quote(scenario.base))
      let report = sync(first.subject)
      io.println(
        first.name
        <> " syncs: server stores "
        <> int.to_string(report.text_stored)
        <> " operations",
      )
      list.each(peers, fn(peer) {
        case peer.name == first.name {
          True -> Nil
          False -> {
            let report = sync(peer.subject)
            io.println(
              peer.name
              <> " syncs: receives "
              <> int.to_string(report.text_forwarded)
              <> " operations",
            )
            Nil
          }
        }
      })
      Nil
    }
    Error(_) -> Nil
  }
}

fn edit_offline(scenario: Scenario, peers: List(ConnectedPeer)) -> Nil {
  io.println("")
  io.println("2. Offline edits (no network)")
  io.println("------------------------------")
  list.each(scenario.replicas, fn(replica) {
    case find_peer(peers, replica.name) {
      Ok(peer) -> {
        list.each(replica.text, fn(edit) {
          case edit {
            EditInsert(index:, value:) -> {
              let before = snapshot(peer.subject).text
              let after = edit_insert(peer.subject, index, value).text
              io.println(
                peer.name
                <> " inserts "
                <> quote(value)
                <> " at index "
                <> int.to_string(index),
              )
              io.println("    " <> before <> "  ->  " <> after)
              Nil
            }
            EditDelete(index:, count:) -> {
              let before = snapshot(peer.subject).text
              let after = edit_delete(peer.subject, index, count).text
              io.println(
                peer.name
                <> " deletes "
                <> int.to_string(count)
                <> " graphemes at index "
                <> int.to_string(index),
              )
              io.println("    " <> before <> "  ->  " <> after)
              Nil
            }
            _ -> Nil
          }
        })
        list.each(replica.register, fn(edit) {
          case edit {
            EditSetRegister(value:) -> {
              let _ = set_register(peer.subject, value)
              io.println(peer.name <> " sets register to " <> quote(value))
              Nil
            }
            _ -> Nil
          }
        })
        list.each(replica.set, fn(edit) {
          case edit {
            EditAdd(value:) -> {
              let _ = add_set(peer.subject, value)
              io.println(peer.name <> " adds " <> quote(value) <> " to set")
              Nil
            }
            EditRemove(value:) -> {
              let _ = remove_set(peer.subject, value)
              io.println(
                peer.name <> " removes " <> quote(value) <> " from set",
              )
              Nil
            }
            _ -> Nil
          }
        })
        Nil
      }
      Error(_) -> Nil
    }
  })
  Nil
}

fn sync_until_settled(peers: List(ConnectedPeer)) -> Nil {
  io.println("")
  io.println("3. Converge through the server")
  io.println("-------------------------------")
  let _ = sync_rounds(peers, list.length(peers) + 1)
  Nil
}

fn sync_rounds(peers: List(ConnectedPeer), rounds_left: Int) -> Bool {
  case rounds_left > 0 {
    False -> False
    True -> {
      let forwarded = sync_all(peers)
      case forwarded > 0 {
        True -> sync_rounds(peers, rounds_left - 1)
        False -> False
      }
    }
  }
}

fn sync_all(peers: List(ConnectedPeer)) -> Int {
  list.fold(peers, 0, fn(acc, peer) {
    let report = sync(peer.subject)
    let stored = report.text_stored + report.register_stored + report.set_stored
    let forwarded =
      report.text_forwarded + report.register_forwarded + report.set_forwarded
    io.println(
      peer.name
      <> " syncs: sends "
      <> int.to_string(stored)
      <> " new, receives "
      <> int.to_string(forwarded),
    )
    acc + forwarded
  })
}

fn final_report(
  scenario: Scenario,
  peers: List(ConnectedPeer),
) -> Result(String, String) {
  io.println("")
  io.println("4. Final state")
  io.println("---------------")
  let snaps = list.map(peers, fn(peer) { #(peer.name, snapshot(peer.subject)) })
  list.each(snaps, fn(entry) {
    let #(name, snap) = entry
    io.println(name)
    io.println("    text     " <> quote(snap.text))
    io.println("    register " <> quote(snap.register))
    io.println("    set      " <> list_string(sorted_set(snap.set)))
    Nil
  })
  case verify(scenario, snaps) {
    Ok(Nil) -> Ok("Result: converged to the expected state.")
    Error(reason) -> Error(reason)
  }
}

fn verify(
  scenario: Scenario,
  snaps: List(#(String, PeerSnapshot)),
) -> Result(Nil, String) {
  case list.first(snaps) {
    Ok(#(_, first)) -> {
      let same_text =
        list.all(snaps, fn(entry) {
          let #(_, snap) = entry
          snap.text == first.text
        })
      let same_register =
        list.all(snaps, fn(entry) {
          let #(_, snap) = entry
          snap.register == first.register
        })
      let same_set =
        list.all(snaps, fn(entry) {
          let #(_, snap) = entry
          sorted_set(snap.set) == sorted_set(first.set)
        })
      let matches_expected =
        first.text == scenario.expected_text
        && first.register == scenario.expected_register
        && sorted_set(first.set)
        == list.sort(scenario.expected_set, by: string.compare)
      case same_text && same_register && same_set && matches_expected {
        True -> Ok(Nil)
        False -> Error("replicas did not converge to the expected state")
      }
    }
    Error(_) -> Error("no replicas to check")
  }
}

fn sorted_set(members: set.Set(String)) -> List(String) {
  members |> set.to_list |> list.sort(by: string.compare)
}

fn list_string(values: List(String)) -> String {
  "[" <> string.join(list.map(values, quote), ", ") <> "]"
}

fn demo_scenario() -> Scenario {
  Scenario(
    title: "Field notes merge",
    base: "The quick brown fox",
    replicas: [
      Replica(
        name: "alice-1",
        text: [EditInsert(index: 16, value: "lazy ")],
        register: [
          EditSetRegister("Driftlog v0.3"),
          EditSetRegister("Driftlog v0.3-final"),
        ],
        set: [EditAdd("erlang"), EditAdd("gleam")],
      ),
      Replica(
        name: "bob-1",
        text: [
          EditDelete(index: 10, count: 6),
          EditInsert(index: 13, value: " dog"),
        ],
        register: [EditSetRegister("draft")],
        set: [EditAdd("crdt"), EditAdd("draft"), EditRemove("draft")],
      ),
    ],
    expected_text: "The quick lazy fox dog",
    expected_register: "Driftlog v0.3-final",
    expected_set: ["crdt", "erlang", "gleam"],
  )
}

fn replay(path: String) {
  case net.read_file(path) {
    Ok(bits) -> {
      case bit_array.to_string(bits) {
        Ok(data) -> {
          case decode_scenario(data) {
            Ok(scenario) -> run(scenario)
            Error(reason) -> io.println("Invalid fixture: " <> reason)
          }
        }
        Error(_) -> io.println("Fixture is not valid UTF-8")
      }
    }
    Error(reason) -> io.println("Could not read fixture: " <> reason)
  }
}

fn server_mode(port: Result(Int, Nil)) {
  case port {
    Ok(port) -> {
      case server.start(port) {
        Ok(#(_, bound)) -> {
          print_banner("Standalone sync server")
          io.println("Listening on " <> host <> ":" <> int.to_string(bound))
          io.println("Press Ctrl+C to stop.")
          process.sleep_forever()
        }
        Error(reason) -> io.println("Could not start server: " <> reason)
      }
    }
    Error(_) ->
      io.println("Port must be a number. Use `gleam run -- server 0`.")
  }
}

fn find_peer(
  peers: List(ConnectedPeer),
  name: String,
) -> Result(ConnectedPeer, Nil) {
  list.find(peers, fn(peer) { peer.name == name })
}

fn print_banner(title: String) {
  io.println("")
  io.println("DRIFTLOG " <> demo_version)
  io.println(
    "Conflict-free replicated data types for offline-first collaboration",
  )
  io.println("")
  io.println(title)
  io.println(string.repeat("-", times: string.length(title)))
}

fn usage() {
  io.println("Driftlog demo")
  io.println("")
  io.println("  gleam run                 run the socket demo")
  io.println("  gleam run -- replay FILE  replay a fixture file")
  io.println("  gleam run -- server PORT  run a standalone sync server")
}

fn quote(text: String) -> String {
  "\"" <> text <> "\""
}
