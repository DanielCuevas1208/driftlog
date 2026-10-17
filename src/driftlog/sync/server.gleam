//// Sync server.
////
//// The server stores operations and forwards them. It is a relay, not a
//// participant: it never interprets an operation, so one server can serve
//// any document type. Operations are stored per room (document id) in arrival
//// order. Delta requests receive operations outside their known id set.
////
//// The server is an OTP actor. A separate accept loop accepts connections and
//// spawns one handler process per connection. Each handler runs one sync
//// exchange against the actor.

import driftlog/sync/net
import driftlog/sync/protocol.{
  type DeltaRequest, type DeltaResponse, type Request, type Response,
  type WireOp, decode_delta_request, decode_request, encode_delta_response,
  encode_response, op_id,
}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// A message the server actor accepts.
pub type ServerMessage {
  /// Handle one sync request and reply with its response.
  Sync(reply_to: process.Subject(Response), request: Request)
  /// Handle one state-delta request and reply with its response.
  DeltaSync(reply_to: process.Subject(DeltaResponse), request: DeltaRequest)
  /// Stop the actor and its accept loop.
  Stop
}

/// The stored state of one room.
pub type RoomState {
  RoomState(ops: List(WireOp), seen: Set(String))
}

/// The state of the server actor.
pub type ServerState {
  ServerState(rooms: Dict(String, RoomState), listener: process.Pid)
}

/// Start a server on a port. Port 0 asks the OS for a free port.
///
/// Returns the server's subject and the port it is bound to.
pub fn start(
  port: Int,
) -> Result(#(process.Subject(ServerMessage), Int), String) {
  case net.listen(port) {
    Ok(listen_socket) -> {
      let builder =
        actor.new_with_initialiser(2000, fn(subject) {
          let listener =
            process.spawn(fn() { accept_loop(listen_socket, subject) })
          let state = ServerState(rooms: dict.new(), listener:)
          let bound_port = net.port(listen_socket)
          Ok(
            actor.initialised(state)
            |> actor.returning(#(subject, bound_port)),
          )
        })
      let builder = actor.on_message(builder, handle)
      case actor.start(builder) {
        Ok(started) -> Ok(started.data)
        Error(_) -> Error("server actor failed to start")
      }
    }
    Error(reason) -> Error(reason)
  }
}

/// Stop the server actor and its accept loop.
pub fn stop(server: process.Subject(ServerMessage)) -> Nil {
  process.send(server, Stop)
}

/// Ask the server to run one sync exchange.
pub fn sync(
  server: process.Subject(ServerMessage),
  request: Request,
) -> Response {
  actor.call(server, 10_000, Sync(_, request))
}

/// Ask the server to exchange a state delta.
pub fn sync_delta(
  server: process.Subject(ServerMessage),
  request: DeltaRequest,
) -> DeltaResponse {
  actor.call(server, 10_000, DeltaSync(_, request))
}

fn handle(
  state: ServerState,
  message: ServerMessage,
) -> actor.Next(ServerState, ServerMessage) {
  case message {
    Sync(reply_to:, request:) -> {
      let #(rooms, response) = process_request(state.rooms, request)
      process.send(reply_to, response)
      actor.continue(ServerState(rooms:, listener: state.listener))
    }
    DeltaSync(reply_to:, request:) -> {
      let #(rooms, response) = process_delta_request(state.rooms, request)
      process.send(reply_to, response)
      actor.continue(ServerState(rooms:, listener: state.listener))
    }
    Stop -> {
      process.kill(state.listener)
      actor.stop()
    }
  }
}

fn process_request(
  rooms: Dict(String, RoomState),
  request: Request,
) -> #(Dict(String, RoomState), Response) {
  let room_state =
    result.unwrap(
      dict.get(rooms, request.room),
      RoomState(ops: [], seen: set.new()),
    )
  let #(new_ops, seen) = new_operations(room_state.seen, request.ops)
  let ops = list.append(room_state.ops, new_ops)
  let forward = list.drop(ops, request.cursor)
  let cursor = list.length(ops)
  let stored = list.length(new_ops)
  #(
    dict.insert(rooms, request.room, RoomState(ops:, seen:)),
    protocol.Response(forward:, cursor:, stored:),
  )
}

fn process_delta_request(
  rooms: Dict(String, RoomState),
  request: DeltaRequest,
) -> #(Dict(String, RoomState), DeltaResponse) {
  let room_state =
    result.unwrap(
      dict.get(rooms, request.room),
      RoomState(ops: [], seen: set.new()),
    )
  let #(new_ops, seen) = new_operations(room_state.seen, request.ops)
  let ops = list.append(room_state.ops, new_ops)
  let forward =
    list.filter(ops, fn(op) { !set.contains(request.known, op_id(op)) })
  #(
    dict.insert(rooms, request.room, RoomState(ops:, seen:)),
    protocol.DeltaResponse(forward:, stored: list.length(new_ops)),
  )
}

fn new_operations(
  seen: Set(String),
  incoming: List(WireOp),
) -> #(List(WireOp), Set(String)) {
  let #(reversed, seen) =
    list.fold(incoming, #([], seen), fn(acc, op) {
      let #(new_ops, seen) = acc
      case set.contains(seen, op_id(op)) {
        True -> #(new_ops, seen)
        False -> #([op, ..new_ops], set.insert(seen, op_id(op)))
      }
    })
  #(list.reverse(reversed), seen)
}

fn accept_loop(
  listen_socket: net.Socket,
  server: process.Subject(ServerMessage),
) -> Nil {
  case net.accept(listen_socket) {
    Ok(socket) -> {
      let _ = process.spawn(fn() { handle_connection(socket, server) })
      accept_loop(listen_socket, server)
    }
    Error(_) -> Nil
  }
}

fn handle_connection(
  socket: net.Socket,
  server: process.Subject(ServerMessage),
) -> Nil {
  case net.read_line(socket, <<>>) {
    Ok(line) -> handle_line(socket, server, line)
    Error(_) -> Nil
  }
  net.close(socket)
}

fn handle_line(
  socket: net.Socket,
  server: process.Subject(ServerMessage),
  line: String,
) -> Nil {
  case decode_delta_request(line) {
    Ok(request) -> {
      let response = actor.call(server, 10_000, DeltaSync(_, request))
      let _ =
        net.send(
          socket,
          bit_array.from_string(encode_delta_response(response) <> line_end()),
        )
      Nil
    }
    Error(_) -> {
      case decode_request(line) {
        Ok(request) -> {
          let response = actor.call(server, 10_000, Sync(_, request))
          let _ =
            net.send(
              socket,
              bit_array.from_string(encode_response(response) <> line_end()),
            )
          Nil
        }
        Error(_) -> Nil
      }
    }
  }
}

fn line_end() -> String {
  case string.utf_codepoint(10) {
    Ok(codepoint) -> string.from_utf_codepoints([codepoint])
    Error(_) -> ""
  }
}
