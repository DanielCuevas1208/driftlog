//// Wire protocol for Driftlog sync.
////
//// A sync exchange is one request and one response, both newline-terminated
//// JSON. The request carries the replica name, the room (document id), a
//// cursor, and the local operations the replica has not sent yet. The
//// response carries the operations the server forwards, the new cursor, and
//// the number of operations the server stored.
////
//// Operations are addressed by a stable id, so a server can drop duplicates
//// and a client can apply an operation twice without changing its state.
////
//// Delta requests carry the operation ids already held by a peer. The server
//// returns only operations outside that known set.

import driftlog/clock.{type Atom, type Stamp, Atom, Stamp, atom_id, stamp_id}
import driftlog/orset
import driftlog/register
import driftlog/rga.{type ListOp}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// An operation in a form that JSON can carry.
///
/// Register values, list values, and set values are strings. A text document
/// maps directly; a generic register converts to strings on the wire.
pub type WireOp {
  WireSet(value: String, stamp: Stamp)
  WireInsert(atom: Atom, parent: Atom, value: String)
  WireDelete(atom: Atom)
  WireAdd(atom: Atom, value: String)
  WireRemove(atom: Atom)
}

/// A client-to-server sync request.
pub type Request {
  Request(peer: String, room: String, cursor: Int, ops: List(WireOp))
}

/// A server-to-client sync response.
pub type Response {
  Response(forward: List(WireOp), cursor: Int, stored: Int)
}

/// A state-delta sync request.
///
/// `known` contains operation ids already held by the peer. The server can
/// return only operations outside that set, even when delivery was sparse.
pub type DeltaRequest {
  DeltaRequest(
    peer: String,
    room: String,
    known: Set(String),
    ops: List(WireOp),
  )
}

/// A state-delta sync response.
pub type DeltaResponse {
  DeltaResponse(forward: List(WireOp), stored: Int)
}

/// A stable identifier for an operation.
pub fn op_id(op: WireOp) -> String {
  case op {
    WireSet(stamp:, ..) -> "set:" <> stamp_id(stamp)
    WireInsert(atom:, ..) -> "insert:" <> atom_id(atom)
    WireDelete(atom:) -> "delete:" <> atom_id(atom)
    WireAdd(atom:, ..) -> "add:" <> atom_id(atom)
    WireRemove(atom:) -> "remove:" <> atom_id(atom)
  }
}

/// Convert a list operation to its wire form.
pub fn list_op_to_wire(op: ListOp(String)) -> WireOp {
  case op {
    rga.Insert(atom:, parent:, value:) -> WireInsert(atom:, parent:, value:)
    rga.Delete(atom:) -> WireDelete(atom:)
  }
}

/// Convert a wire operation to a list operation.
pub fn wire_to_list_op(op: WireOp) -> Result(ListOp(String), Nil) {
  case op {
    WireInsert(atom:, parent:, value:) -> Ok(rga.Insert(atom:, parent:, value:))
    WireDelete(atom:) -> Ok(rga.Delete(atom:))
    WireSet(..) -> Error(Nil)
    WireAdd(..) -> Error(Nil)
    WireRemove(..) -> Error(Nil)
  }
}

/// Convert a register operation to its wire form.
pub fn register_op_to_wire(op: register.RegisterOp(String)) -> WireOp {
  case op {
    register.Set(value:, stamp:) -> WireSet(value:, stamp:)
  }
}

/// Convert a wire operation to a register operation.
pub fn wire_to_register_op(
  op: WireOp,
) -> Result(register.RegisterOp(String), Nil) {
  case op {
    WireSet(value:, stamp:) -> Ok(register.Set(value:, stamp:))
    WireInsert(..) -> Error(Nil)
    WireDelete(..) -> Error(Nil)
    WireAdd(..) -> Error(Nil)
    WireRemove(..) -> Error(Nil)
  }
}

/// Convert a set operation to its wire form.
pub fn set_op_to_wire(op: orset.OrsetOp(String)) -> WireOp {
  case op {
    orset.Add(atom:, value:) -> WireAdd(atom:, value:)
    orset.Remove(atom:) -> WireRemove(atom:)
  }
}

/// Convert a wire operation to a set operation.
pub fn wire_to_set_op(op: WireOp) -> Result(orset.OrsetOp(String), Nil) {
  case op {
    WireAdd(atom:, value:) -> Ok(orset.Add(atom:, value:))
    WireRemove(atom:) -> Ok(orset.Remove(atom:))
    WireSet(..) -> Error(Nil)
    WireInsert(..) -> Error(Nil)
    WireDelete(..) -> Error(Nil)
  }
}

/// Encode a request to one JSON line.
pub fn encode_request(request: Request) -> String {
  json.object([
    #("peer", json.string(request.peer)),
    #("room", json.string(request.room)),
    #("cursor", json.int(request.cursor)),
    #("ops", json.array(from: request.ops, of: wire_op_to_json)),
  ])
  |> json.to_string
}

/// Decode a request from one JSON line.
pub fn decode_request(line: String) -> Result(Request, String) {
  json.parse(from: line, using: request_decoder())
  |> result.map_error(fn(_) { "malformed request" })
}

/// Encode a response to one JSON line.
pub fn encode_response(response: Response) -> String {
  json.object([
    #("forward", json.array(from: response.forward, of: wire_op_to_json)),
    #("cursor", json.int(response.cursor)),
    #("stored", json.int(response.stored)),
  ])
  |> json.to_string
}

/// Decode a response from one JSON line.
pub fn decode_response(line: String) -> Result(Response, String) {
  json.parse(from: line, using: response_decoder())
  |> result.map_error(fn(_) { "malformed response" })
}

/// Encode a state-delta request to one JSON line.
pub fn encode_delta_request(request: DeltaRequest) -> String {
  json.object([
    #("mode", json.string("delta")),
    #("peer", json.string(request.peer)),
    #("room", json.string(request.room)),
    #(
      "known",
      json.array(
        from: request.known |> set.to_list |> list.sort(by: string.compare),
        of: json.string,
      ),
    ),
    #("ops", json.array(from: request.ops, of: wire_op_to_json)),
  ])
  |> json.to_string
}

/// Decode a state-delta request from one JSON line.
pub fn decode_delta_request(line: String) -> Result(DeltaRequest, String) {
  json.parse(from: line, using: delta_request_decoder())
  |> result.map_error(fn(_) { "malformed delta request" })
}

/// Encode a state-delta response to one JSON line.
pub fn encode_delta_response(response: DeltaResponse) -> String {
  json.object([
    #("mode", json.string("delta")),
    #("forward", json.array(from: response.forward, of: wire_op_to_json)),
    #("stored", json.int(response.stored)),
  ])
  |> json.to_string
}

/// Decode a state-delta response from one JSON line.
pub fn decode_delta_response(line: String) -> Result(DeltaResponse, String) {
  json.parse(from: line, using: delta_response_decoder())
  |> result.map_error(fn(_) { "malformed delta response" })
}

fn wire_op_to_json(op: WireOp) -> json.Json {
  case op {
    WireSet(value:, stamp:) ->
      json.object([
        #("kind", json.string("set")),
        #("value", json.string(value)),
        #("stamp", stamp_to_json(stamp)),
      ])
    WireInsert(atom:, parent:, value:) ->
      json.object([
        #("kind", json.string("insert")),
        #("atom", atom_to_json(atom)),
        #("parent", atom_to_json(parent)),
        #("value", json.string(value)),
      ])
    WireDelete(atom:) ->
      json.object([
        #("kind", json.string("delete")),
        #("atom", atom_to_json(atom)),
      ])
    WireAdd(atom:, value:) ->
      json.object([
        #("kind", json.string("add")),
        #("atom", atom_to_json(atom)),
        #("value", json.string(value)),
      ])
    WireRemove(atom:) ->
      json.object([
        #("kind", json.string("remove")),
        #("atom", atom_to_json(atom)),
      ])
  }
}

fn stamp_to_json(stamp: Stamp) -> json.Json {
  json.object([
    #("logical", json.int(stamp.logical)),
    #("node", json.string(stamp.node)),
  ])
}

fn atom_to_json(atom: Atom) -> json.Json {
  stamp_to_json(atom.stamp)
}

fn request_decoder() -> decode.Decoder(Request) {
  use peer <- decode.field("peer", decode.string)
  use room <- decode.field("room", decode.string)
  use cursor <- decode.field("cursor", decode.int)
  use ops <- decode.field("ops", decode.list(of: wire_op_decoder()))
  decode.success(Request(peer:, room:, cursor:, ops:))
}

fn response_decoder() -> decode.Decoder(Response) {
  use forward <- decode.field("forward", decode.list(of: wire_op_decoder()))
  use cursor <- decode.field("cursor", decode.int)
  use stored <- decode.field("stored", decode.int)
  decode.success(Response(forward:, cursor:, stored:))
}

fn delta_request_decoder() -> decode.Decoder(DeltaRequest) {
  use mode <- decode.field("mode", decode.string)
  case mode {
    "delta" -> {
      use peer <- decode.field("peer", decode.string)
      use room <- decode.field("room", decode.string)
      use known_ids <- decode.field("known", decode.list(of: decode.string))
      use ops <- decode.field("ops", decode.list(of: wire_op_decoder()))
      let known =
        list.fold(known_ids, set.new(), fn(acc, id) { set.insert(acc, id) })
      decode.success(DeltaRequest(peer:, room:, known:, ops:))
    }
    _ ->
      decode.failure(
        DeltaRequest(peer: "", room: "", known: set.new(), ops: []),
        "delta request mode",
      )
  }
}

fn delta_response_decoder() -> decode.Decoder(DeltaResponse) {
  use mode <- decode.field("mode", decode.string)
  case mode {
    "delta" -> {
      use forward <- decode.field("forward", decode.list(of: wire_op_decoder()))
      use stored <- decode.field("stored", decode.int)
      decode.success(DeltaResponse(forward:, stored:))
    }
    _ ->
      decode.failure(
        DeltaResponse(forward: [], stored: 0),
        "delta response mode",
      )
  }
}

fn wire_op_decoder() -> decode.Decoder(WireOp) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "set" -> {
      use value <- decode.field("value", decode.string)
      use stamp <- decode.field("stamp", stamp_decoder())
      decode.success(WireSet(value:, stamp:))
    }
    "insert" -> {
      use atom <- decode.field("atom", atom_decoder())
      use parent <- decode.field("parent", atom_decoder())
      use value <- decode.field("value", decode.string)
      decode.success(WireInsert(atom:, parent:, value:))
    }
    "delete" -> {
      use atom <- decode.field("atom", atom_decoder())
      decode.success(WireDelete(atom:))
    }
    "add" -> {
      use atom <- decode.field("atom", atom_decoder())
      use value <- decode.field("value", decode.string)
      decode.success(WireAdd(atom:, value:))
    }
    "remove" -> {
      use atom <- decode.field("atom", atom_decoder())
      decode.success(WireRemove(atom:))
    }
    _ -> decode.failure(WireSet(value: "", stamp: Stamp(0, "")), "wire op kind")
  }
}

fn stamp_decoder() -> decode.Decoder(Stamp) {
  use logical <- decode.field("logical", decode.int)
  use node <- decode.field("node", decode.string)
  decode.success(Stamp(logical:, node:))
}

fn atom_decoder() -> decode.Decoder(Atom) {
  use logical <- decode.field("logical", decode.int)
  use node <- decode.field("node", decode.string)
  decode.success(Atom(Stamp(logical:, node:)))
}
