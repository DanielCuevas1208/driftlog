//// Sync client.
////
//// A client performs one round trip per call: it opens a connection, sends a
//// request line, reads one response line, and closes. A cursor tracks how
//// many operations the server has forwarded to this replica, so the next
//// call only asks for what is new.

import driftlog/sync/net
import driftlog/sync/protocol.{type Response, type WireOp}
import gleam/bit_array

/// Exchange operations with a sync server.
///
/// `peer` names this replica. `room` names the document. `cursor` is the
/// number of operations this replica has already seen. `ops` are the local
/// operations this replica has not sent yet.
pub fn sync(
  peer: String,
  host: String,
  port: Int,
  room: String,
  cursor: Int,
  ops: List(WireOp),
) -> Result(Response, String) {
  case net.connect(host, port) {
    Ok(socket) -> {
      let request = protocol.Request(peer:, room:, cursor:, ops:)
      let line = protocol.encode_request(request) <> "\n"
      case net.send(socket, bit_array.from_string(line)) {
        Ok(_) -> {
          case net.read_line(socket, <<>>) {
            Ok(line) -> {
              net.close(socket)
              protocol.decode_response(line)
            }
            Error(reason) -> {
              net.close(socket)
              Error(reason)
            }
          }
        }
        Error(reason) -> {
          net.close(socket)
          Error(reason)
        }
      }
    }
    Error(reason) -> Error(reason)
  }
}
