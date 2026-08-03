//// A replica peer.
////
//// A peer owns a text document, a register, and a set, plus the operations
//// it has not sent yet. Local edits append to the pending queues. A sync
//// sends the pending operations to the server for each room, applies what
//// the server forwards, and advances the cursors. Local edits and syncs run
//// inside an actor, so the peer never interleaves them.

import driftlog/orset
import driftlog/register
import driftlog/sync/client
import driftlog/sync/protocol.{
  type WireOp, list_op_to_wire, register_op_to_wire, set_op_to_wire,
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
  let builder = actor.new(state) |> actor.on_message(handle)
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
  state: PeerState,
  message: PeerMessage,
) -> actor.Next(PeerState, PeerMessage) {
  case message {
    EditInsert(reply_to:, index:, value:) -> {
      let #(document, ops) = text.insert_string(state.document, index, value)
      let pending =
        list.append(state.pending_text, list.map(ops, list_op_to_wire))
      let state = PeerState(..state, document:, pending_text: pending)
      process.send(reply_to, snapshot_of(state))
      actor.continue(state)
    }
    EditDelete(reply_to:, index:, count:) -> {
      case text.delete_range(state.document, index, count) {
        Ok(#(document, ops)) -> {
          let pending =
            list.append(state.pending_text, list.map(ops, list_op_to_wire))
          let state = PeerState(..state, document:, pending_text: pending)
          process.send(reply_to, snapshot_of(state))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply_to, snapshot_of(state))
          actor.continue(state)
        }
      }
    }
    SetRegister(reply_to:, value:) -> {
      let #(register, op) = register.write(state.register, value)
      let pending =
        list.append(state.pending_register, [register_op_to_wire(op)])
      let state = PeerState(..state, register:, pending_register: pending)
      process.send(reply_to, snapshot_of(state))
      actor.continue(state)
    }
    AddSet(reply_to:, value:) -> {
      let #(set, op) = orset.add(state.set, value)
      let pending = list.append(state.pending_set, [set_op_to_wire(op)])
      let state = PeerState(..state, set:, pending_set: pending)
      process.send(reply_to, snapshot_of(state))
      actor.continue(state)
    }
    RemoveSet(reply_to:, value:) -> {
      let #(set, ops) = orset.remove(state.set, value)
      let pending =
        list.append(state.pending_set, list.map(ops, set_op_to_wire))
      let state = PeerState(..state, set:, pending_set: pending)
      process.send(reply_to, snapshot_of(state))
      actor.continue(state)
    }
    Sync(reply_to:) -> {
      let #(state, text_stored, text_forwarded) = sync_text(state)
      let #(state, register_stored, register_forwarded) = sync_register(state)
      let #(state, set_stored, set_forwarded) = sync_set(state)
      process.send(
        reply_to,
        SyncReport(
          snapshot: snapshot_of(state),
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
      process.send(reply_to, snapshot_of(state))
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

fn sync_text(state: PeerState) -> #(PeerState, Int, Int) {
  case
    client.sync(
      state.peer,
      state.host,
      state.port,
      text_room,
      state.text_cursor,
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
      let state =
        PeerState(
          ..state,
          document:,
          text_cursor: response.cursor,
          pending_text: [],
        )
      #(state, response.stored, list.length(response.forward))
    }
    Error(_) -> #(state, 0, 0)
  }
}

fn sync_register(state: PeerState) -> #(PeerState, Int, Int) {
  case
    client.sync(
      state.peer,
      state.host,
      state.port,
      register_room,
      state.register_cursor,
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
      let state =
        PeerState(
          ..state,
          register: reg,
          register_cursor: response.cursor,
          pending_register: [],
        )
      #(state, response.stored, list.length(response.forward))
    }
    Error(_) -> #(state, 0, 0)
  }
}

fn sync_set(state: PeerState) -> #(PeerState, Int, Int) {
  case
    client.sync(
      state.peer,
      state.host,
      state.port,
      set_room,
      state.set_cursor,
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
      let state =
        PeerState(..state, set:, set_cursor: response.cursor, pending_set: [])
      #(state, response.stored, list.length(response.forward))
    }
    Error(_) -> #(state, 0, 0)
  }
}
