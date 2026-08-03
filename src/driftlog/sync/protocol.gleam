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

import driftlog/clock.{type Atom, type Stamp, Atom, Stamp, atom_id, stamp_id}
import driftlog/register
import driftlog/rga.{type ListOp}
import gleam/dynamic/decode
import gleam/json
import gleam/result

/// An operation in a form that JSON can carry.
///
/// Register values and list values are strings. A text document maps
/// directly; a generic register converts to strings on the wire.
pub type WireOp {
  WireSet(value: String, stamp: Stamp)
  WireInsert(atom: Atom, parent: Atom, value: String)
  WireDelete(atom: Atom)
}

/// A client-to-server sync request.
pub type Request {
  Request(peer: String, room: String, cursor: Int, ops: List(WireOp))
}

/// A server-to-client sync response.
pub type Response {
  Response(forward: List(WireOp), cursor: Int, stored: Int)
}

/// A stable identifier for an operation.
pub fn op_id(op: WireOp) -> String {
  case op {
    WireSet(stamp:, ..) -> "set:" <> stamp_id(stamp)
    WireInsert(atom:, ..) -> "insert:" <> atom_id(atom)
    WireDelete(atom:) -> "delete:" <> atom_id(atom)
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
