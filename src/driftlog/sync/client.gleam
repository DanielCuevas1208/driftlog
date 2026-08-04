//// Sync client.
////
//// A client performs one round trip per call: it opens a connection, sends a
//// request line, reads one response line, and closes. Cursor sync supports
//// ordered replay. Delta sync uses operation ids when delivery is sparse.

import driftlog/sync/net
import driftlog/sync/protocol.{type Response, type WireOp}
import gleam/bit_array
import gleam/set.{type Set}
import gleam/string

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

/// Exchange a state delta with a sync server.
///
/// The known set lists operation ids already held by the peer. The server
/// returns operations outside that set and stores new operations.
pub fn sync_delta(
  peer: String,
  host: String,
  port: Int,
  room: String,
  known: Set(String),
  ops: List(WireOp),
) -> Result(protocol.DeltaResponse, String) {
  case net.connect(host, port) {
    Ok(socket) -> {
      let request = protocol.DeltaRequest(peer:, room:, known:, ops:)
      let line = protocol.encode_delta_request(request) <> line_end()
      case net.send(socket, bit_array.from_string(line)) {
        Ok(_) -> {
          case net.read_line(socket, <<>>) {
            Ok(line) -> {
              net.close(socket)
              protocol.decode_delta_response(line)
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

fn line_end() -> String {
  case string.utf_codepoint(10) {
    Ok(codepoint) -> string.from_utf_codepoints([codepoint])
    Error(_) -> ""
  }
}
