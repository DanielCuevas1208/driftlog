//// A replica peer.
////
//// A peer owns a text document, a register, and a set, plus the operations
//// it has not sent yet. Local edits append to pending queues. A sync sends
//// pending operations and known ids for each room. Local edits and syncs run
//// inside an actor, so the peer never interleaves them.

import driftlog/orset
import driftlog/register
import driftlog/sync/client
import driftlog/sync/protocol.{
  type WireOp, list_op_to_wire, op_id, register_op_to_wire, set_op_to_wire,
  wire_to_list_op, wire_to_register_op, wire_to_set_op,
}
import driftlog/text
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/set.{type Set}

/// A view of a peer's documents.
pub type PeerSnapshot {
  PeerSnapshot(text: String, register: String, set: Set(String))
}

/// The outcome of one sync.
pub type SyncReport {
  SyncReport(
    snapshot: PeerSnapshot,
    text_stored: Int,
    text_forwarded: Int,
    register_stored: Int,
    register_forwarded: Int,
    set_stored: Int,
    set_forwarded: Int,
  )
}

/// A message the peer actor accepts.
pub type PeerMessage {
  EditInsert(reply_to: process.Subject(PeerSnapshot), index: Int, value: String)
  EditDelete(reply_to: process.Subject(PeerSnapshot), index: Int, count: Int)
  SetRegister(reply_to: process.Subject(PeerSnapshot), value: String)
  AddSet(reply_to: process.Subject(PeerSnapshot), value: String)
  RemoveSet(reply_to: process.Subject(PeerSnapshot), value: String)
  Sync(reply_to: process.Subject(SyncReport))
  Snapshot(reply_to: process.Subject(PeerSnapshot))
  Stop
}

/// The state of a peer actor.
pub type PeerState {
  PeerState(
    peer: String,
    host: String,
    port: Int,
    document: text.Text,
    register: register.Register(String),
    set: orset.Orset(String),
    pending_text: List(WireOp),
    pending_register: List(WireOp),
    pending_set: List(WireOp),
    text_cursor: Int,
    register_cursor: Int,
    set_cursor: Int,
  )
}

type RuntimeState {
  RuntimeState(
    peer_state: PeerState,
    known_text: Set(String),
    known_register: Set(String),
    known_set: Set(String),
  )
}

/// The name of the room that carries text operations.
pub const text_room = "text"

/// The name of the room that carries register operations.
pub const register_room = "register"

/// The name of the room that carries set operations.
pub const set_room = "set"

/// Start a peer actor.
///
/// `peer` must be a unique replica name, such as `"alice-1"`.
pub fn start(
  peer: String,
  host: String,
  port: Int,
) -> Result(process.Subject(PeerMessage), String) {
  let state =
    PeerState(
      peer:,
      host:,
      port:,
      document: text.new(peer),
      register: register.new(peer, ""),
      set: orset.new(peer),
      pending_text: [],
      pending_register: [],
      pending_set: [],
      text_cursor: 0,
      register_cursor: 0,
      set_cursor: 0,
    )
  let builder =
    actor.new(RuntimeState(
      peer_state: state,
      known_text: set.new(),
      known_register: set.new(),
      known_set: set.new(),
    ))
    |> actor.on_message(handle)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(_) -> Error("peer actor failed to start")
  }
}

/// Insert a string into the peer's text document.
pub fn edit_insert(
  peer: process.Subject(PeerMessage),
  index: Int,
  value: String,
) -> PeerSnapshot {
  actor.call(peer, 5000, EditInsert(_, index, value))
}

/// Delete a run of graphemes from the peer's text document.
pub fn edit_delete(
  peer: process.Subject(PeerMessage),
  index: Int,
  count: Int,
) -> PeerSnapshot {
  actor.call(peer, 5000, EditDelete(_, index, count))
}

/// Write a value to the peer's register.
pub fn set_register(
  peer: process.Subject(PeerMessage),
  value: String,
) -> PeerSnapshot {
  actor.call(peer, 5000, SetRegister(_, value))
}

/// Add a value to the peer's set.
pub fn add_set(
  peer: process.Subject(PeerMessage),
  value: String,
) -> PeerSnapshot {
  actor.call(peer, 5000, AddSet(_, value))
}

/// Remove a value from the peer's set.
pub fn remove_set(
  peer: process.Subject(PeerMessage),
  value: String,
) -> PeerSnapshot {
  actor.call(peer, 5000, RemoveSet(_, value))
}

/// Sync both rooms with the server.
pub fn sync(peer: process.Subject(PeerMessage)) -> SyncReport {
  actor.call(peer, 20_000, Sync)
}

/// Read the peer's documents without syncing.
pub fn snapshot(peer: process.Subject(PeerMessage)) -> PeerSnapshot {
  actor.call(peer, 5000, Snapshot)
}

/// Stop the peer actor.
pub fn stop(peer: process.Subject(PeerMessage)) -> Nil {
  process.send(peer, Stop)
}

fn handle(
  state: RuntimeState,
  message: PeerMessage,
) -> actor.Next(RuntimeState, PeerMessage) {
  let peer_state = state.peer_state
  case message {
    EditInsert(reply_to:, index:, value:) -> {
      let #(document, ops) =
        text.insert_string(peer_state.document, index, value)
      let wire_ops = list.map(ops, list_op_to_wire)
      let pending = list.append(peer_state.pending_text, wire_ops)
      let peer_state = PeerState(..peer_state, document:, pending_text: pending)
      let state =
        RuntimeState(
          ..state,
          peer_state:,
          known_text: remember(state.known_text, wire_ops),
        )
      process.send(reply_to, snapshot_of(peer_state))
      actor.continue(state)
    }
    EditDelete(reply_to:, index:, count:) -> {
      case text.delete_range(peer_state.document, index, count) {
        Ok(#(document, ops)) -> {
          let wire_ops = list.map(ops, list_op_to_wire)
          let pending = list.append(peer_state.pending_text, wire_ops)
          let peer_state =
            PeerState(..peer_state, document:, pending_text: pending)
          let state =
            RuntimeState(
              ..state,
              peer_state:,
              known_text: remember(state.known_text, wire_ops),
            )
          process.send(reply_to, snapshot_of(peer_state))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply_to, snapshot_of(peer_state))
          actor.continue(state)
        }
      }
    }
    SetRegister(reply_to:, value:) -> {
      let #(register, op) = register.write(peer_state.register, value)
      let wire_op = register_op_to_wire(op)
      let pending = list.append(peer_state.pending_register, [wire_op])
      let peer_state =
        PeerState(..peer_state, register:, pending_register: pending)
      let state =
        RuntimeState(
          ..state,
          peer_state:,
          known_register: remember(state.known_register, [wire_op]),
        )
      process.send(reply_to, snapshot_of(peer_state))
      actor.continue(state)
    }
    AddSet(reply_to:, value:) -> {
      let #(set, op) = orset.add(peer_state.set, value)
      let wire_op = set_op_to_wire(op)
      let pending = list.append(peer_state.pending_set, [wire_op])
      let peer_state = PeerState(..peer_state, set:, pending_set: pending)
      let state =
        RuntimeState(
          ..state,
          peer_state:,
          known_set: remember(state.known_set, [wire_op]),
        )
      process.send(reply_to, snapshot_of(peer_state))
      actor.continue(state)
    }
    RemoveSet(reply_to:, value:) -> {
      let #(set, ops) = orset.remove(peer_state.set, value)
      let wire_ops = list.map(ops, set_op_to_wire)
      let pending = list.append(peer_state.pending_set, wire_ops)
      let peer_state = PeerState(..peer_state, set:, pending_set: pending)
      let state =
        RuntimeState(
          ..state,
          peer_state:,
          known_set: remember(state.known_set, wire_ops),
        )
      process.send(reply_to, snapshot_of(peer_state))
      actor.continue(state)
    }
    Sync(reply_to:) -> {
      let #(state, text_stored, text_forwarded) = sync_text(state)
      let #(state, register_stored, register_forwarded) = sync_register(state)
      let #(state, set_stored, set_forwarded) = sync_set(state)
      process.send(
        reply_to,
        SyncReport(
          snapshot: snapshot_of(state.peer_state),
          text_stored:,
          text_forwarded:,
          register_stored:,
          register_forwarded:,
          set_stored:,
          set_forwarded:,
        ),
      )
      actor.continue(state)
    }
    Snapshot(reply_to:) -> {
      process.send(reply_to, snapshot_of(peer_state))
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

fn snapshot_of(state: PeerState) -> PeerSnapshot {
  PeerSnapshot(
    text: text.read(state.document),
    register: register.read(state.register),
    set: orset.read(state.set),
  )
}

fn remember(known: Set(String), ops: List(WireOp)) -> Set(String) {
  list.fold(ops, known, fn(acc, op) { set.insert(acc, op_id(op)) })
}

fn sync_text(runtime: RuntimeState) -> #(RuntimeState, Int, Int) {
  let state = runtime.peer_state
  case
    client.sync_delta(
      state.peer,
      state.host,
      state.port,
      text_room,
      runtime.known_text,
      state.pending_text,
    )
  {
    Ok(response) -> {
      let document =
        list.fold(response.forward, state.document, fn(doc, wire_op) {
          case wire_to_list_op(wire_op) {
            Ok(op) -> text.apply(doc, op)
            Error(_) -> doc
          }
        })
      let state = PeerState(..state, document:, pending_text: [])
      let runtime =
        RuntimeState(
          ..runtime,
          peer_state: state,
          known_text: remember(runtime.known_text, response.forward),
        )
      #(runtime, response.stored, list.length(response.forward))
    }
    Error(_) -> #(runtime, 0, 0)
  }
}

fn sync_register(runtime: RuntimeState) -> #(RuntimeState, Int, Int) {
  let state = runtime.peer_state
  case
    client.sync_delta(
      state.peer,
      state.host,
      state.port,
      register_room,
      runtime.known_register,
      state.pending_register,
    )
  {
    Ok(response) -> {
      let reg =
        list.fold(response.forward, state.register, fn(document, wire_op) {
          case wire_to_register_op(wire_op) {
            Ok(op) -> register.apply(document, op)
            Error(_) -> document
          }
        })
      let state = PeerState(..state, register: reg, pending_register: [])
      let runtime =
        RuntimeState(
          ..runtime,
          peer_state: state,
          known_register: remember(runtime.known_register, response.forward),
        )
      #(runtime, response.stored, list.length(response.forward))
    }
    Error(_) -> #(runtime, 0, 0)
  }
}

fn sync_set(runtime: RuntimeState) -> #(RuntimeState, Int, Int) {
  let state = runtime.peer_state
  case
    client.sync_delta(
      state.peer,
      state.host,
      state.port,
      set_room,
      runtime.known_set,
      state.pending_set,
    )
  {
    Ok(response) -> {
      let set =
        list.fold(response.forward, state.set, fn(document, wire_op) {
          case wire_to_set_op(wire_op) {
            Ok(op) -> orset.apply(document, op)
            Error(_) -> document
          }
        })
      let state = PeerState(..state, set:, pending_set: [])
      let runtime =
        RuntimeState(
          ..runtime,
          peer_state: state,
          known_set: remember(runtime.known_set, response.forward),
        )
      #(runtime, response.stored, list.length(response.forward))
    }
    Error(_) -> #(runtime, 0, 0)
  }
}
