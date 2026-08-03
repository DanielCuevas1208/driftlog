//// Sockets for Driftlog sync.
////
//// A small wrapper around the Erlang `gen_tcp` FFI. Sockets are passive and
//// binary. `read_line` frames the protocol: it accumulates bytes until a
//// newline, splitting on the byte value, so a multi-byte UTF-8 character can
//// arrive in separate chunks without being corrupted.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/result
import gleam/string

/// A socket in the internal FFI form.
pub opaque type Socket {
  Socket(handle: Dynamic)
}

@external(erlang, "driftlog_net_ffi", "listen")
fn listen_raw(port: Int) -> Result(Dynamic, String)

@external(erlang, "driftlog_net_ffi", "accept")
fn accept_raw(socket_handle: Dynamic) -> Result(Dynamic, String)

@external(erlang, "driftlog_net_ffi", "connect")
fn connect_raw(host: String, port: Int) -> Result(Dynamic, String)

@external(erlang, "driftlog_net_ffi", "send")
fn send_raw(socket_handle: Dynamic, data: BitArray) -> Result(Int, String)

@external(erlang, "driftlog_net_ffi", "recv")
fn recv_raw(socket_handle: Dynamic) -> Result(BitArray, String)

@external(erlang, "driftlog_net_ffi", "close")
fn close_raw(socket_handle: Dynamic) -> Nil

@external(erlang, "driftlog_net_ffi", "port")
fn port_raw(socket_handle: Dynamic) -> Int

@external(erlang, "driftlog_net_ffi", "read_file")
pub fn read_file(path: String) -> Result(BitArray, String)

@external(erlang, "driftlog_net_ffi", "argv")
pub fn argv() -> List(String)

/// Listen for connections on a port. Port 0 asks the OS for a free port.
pub fn listen(port: Int) -> Result(Socket, String) {
  listen_raw(port) |> result.map(Socket)
}

/// Accept the next connection.
pub fn accept(socket: Socket) -> Result(Socket, String) {
  accept_raw(socket.handle) |> result.map(Socket)
}

/// Connect to a host and port.
pub fn connect(host: String, port: Int) -> Result(Socket, String) {
  connect_raw(host, port) |> result.map(Socket)
}

/// Send raw bytes over a socket.
pub fn send(socket: Socket, data: BitArray) -> Result(Int, String) {
  send_raw(socket.handle, data)
}

/// Receive whatever bytes are available.
pub fn recv(socket: Socket) -> Result(BitArray, String) {
  recv_raw(socket.handle)
}

/// Close a socket.
pub fn close(socket: Socket) -> Nil {
  close_raw(socket.handle)
}

/// The port a listening socket is bound to.
pub fn port(socket: Socket) -> Int {
  port_raw(socket.handle)
}

/// Read one newline-terminated line.
///
/// The buffer is only decoded once it forms valid UTF-8, so a multi-byte
/// character that arrives in separate chunks is reassembled correctly.
pub fn read_line(socket: Socket, buffer: BitArray) -> Result(String, String) {
  case recv(socket) {
    Ok(data) -> {
      let buffer = bit_array.append(buffer, data)
      case bit_array.to_string(buffer) {
        Ok(text) -> {
          case string.split(text, on: "\n") {
            [line, _rest, ..] -> Ok(line)
            _ -> read_line(socket, buffer)
          }
        }
        Error(_) -> read_line(socket, buffer)
      }
    }
    Error(_) -> Error("connection closed before end of line")
  }
}
