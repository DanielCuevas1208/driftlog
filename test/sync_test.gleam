import driftlog/clock.{Atom, Stamp}
import driftlog/sync/client
import driftlog/sync/peer
import driftlog/sync/protocol
import driftlog/sync/server
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should

fn alice_insert(sequence: Int) -> protocol.WireOp {
  protocol.WireInsert(
    atom: Atom(Stamp(sequence, "alice-1")),
    parent: Atom(Stamp(sequence - 1, "alice-1")),
    value: "x",
  )
}

pub fn two_clients_exchange_over_sockets_test() {
  let #(server_subject, port) = server.start(0) |> should.be_ok
  let host = "127.0.0.1"

  // Alice pushes a base of two insertions.
  let first =
    client.sync("alice-1", host, port, "text", 0, [
      alice_insert(1),
      alice_insert(2),
    ])
  should.be_ok(first)

  // Bob pulls: he receives both operations and advances his cursor.
  let second = client.sync("bob-1", host, port, "text", 0, []) |> should.be_ok
  should.equal(second.cursor, 2)
  should.equal(list.length(second.forward), 2)

  // Bob pushes his own insertion.
  let bob_op =
    protocol.WireInsert(
      atom: Atom(Stamp(3, "bob-1")),
      parent: Atom(Stamp(2, "alice-1")),
      value: "y",
    )
  let third =
    client.sync("bob-1", host, port, "text", 2, [bob_op])
    |> should.be_ok
  should.equal(third.cursor, 3)
  should.equal(third.stored, 1)

  // Alice pulls Bob's insertion.
  let fourth = client.sync("alice-1", host, port, "text", 2, []) |> should.be_ok
  should.equal(fourth.cursor, 3)
  should.equal(list.length(fourth.forward), 1)

  server.stop(server_subject)
}

pub fn the_server_drops_duplicate_operations_test() {
  let #(server_subject, port) = server.start(0) |> should.be_ok
  let host = "127.0.0.1"
  let op = alice_insert(1)

  let first =
    client.sync("alice-1", host, port, "text", 0, [op])
    |> should.be_ok
  should.equal(first.stored, 1)
  should.equal(first.cursor, 1)

  // The same operation is sent again from a fresh connection. It must not be
  // stored a second time, and the cursor must not move.
  let second =
    client.sync("alice-1", host, port, "text", 1, [op])
    |> should.be_ok
  should.equal(second.stored, 0)
  should.equal(second.cursor, 1)
  should.equal(list.length(second.forward), 0)

  server.stop(server_subject)
}

pub fn peers_converge_through_the_server_test() {
  let #(server_subject, port) = server.start(0) |> should.be_ok

  let alice = peer.start("alice-1", "127.0.0.1", port) |> should.be_ok
  let bob = peer.start("bob-1", "127.0.0.1", port) |> should.be_ok

  // Seed the shared base document.
  let _ = peer.edit_insert(alice, 0, "ab")
  let _ = peer.sync(alice)
  let _ = peer.sync(bob)

  // Edit offline, then exchange through the server.
  let _ = peer.edit_insert(alice, 1, "X")
  let _ = peer.edit_insert(bob, 1, "Y")
  let _ = peer.sync(alice)
  let _ = peer.sync(bob)
  let _ = peer.sync(alice)
  let _ = peer.sync(bob)

  let alice_snapshot = peer.snapshot(alice)
  let bob_snapshot = peer.snapshot(bob)
  should.equal(alice_snapshot.text, bob_snapshot.text)
  should.equal(alice_snapshot.text, "aYXb")

  peer.stop(alice)
  peer.stop(bob)
  server.stop(server_subject)
}

pub fn the_server_forwards_set_operations_test() {
  let #(server_subject, port) = server.start(0) |> should.be_ok
  let host = "127.0.0.1"
  let add = protocol.WireAdd(atom: Atom(Stamp(1, "alice-1")), value: "gleam")

  let first =
    client.sync("alice-1", host, port, "set", 0, [add])
    |> should.be_ok
  should.equal(first.stored, 1)
  should.equal(first.cursor, 1)

  let second =
    client.sync("bob-1", host, port, "set", 0, [])
    |> should.be_ok
  should.equal(second.forward, [add])
  should.equal(second.cursor, 1)

  server.stop(server_subject)
}

pub fn peers_converge_a_set_through_the_server_test() {
  let #(server_subject, port) = server.start(0) |> should.be_ok

  let alice = peer.start("alice-1", "127.0.0.1", port) |> should.be_ok
  let bob = peer.start("bob-1", "127.0.0.1", port) |> should.be_ok

  // Each peer edits a shared set offline.
  let _ = peer.add_set(alice, "gleam")
  let _ = peer.add_set(alice, "crdt")
  let _ = peer.add_set(bob, "erlang")
  let _ = peer.add_set(bob, "draft")
  let _ = peer.remove_set(bob, "draft")

  // Exchange through the server until the set settles.
  let _ = peer.sync(alice)
  let _ = peer.sync(bob)
  let _ = peer.sync(alice)
  let _ = peer.sync(bob)

  let alice_snapshot = peer.snapshot(alice)
  let bob_snapshot = peer.snapshot(bob)
  should.equal(alice_snapshot.set, bob_snapshot.set)
  should.equal(
    alice_snapshot.set
      |> set.to_list
      |> list.sort(by: string.compare),
    ["crdt", "erlang", "gleam"],
  )

  peer.stop(alice)
  peer.stop(bob)
  server.stop(server_subject)
}
