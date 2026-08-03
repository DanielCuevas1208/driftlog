# Driftlog

Driftlog is a library of conflict-free replicated data types (CRDTs).
Two replicas edit the same data offline.
Then they merge without conflicts.
Any delivery order produces the same result.

The stack is Gleam, Erlang/OTP, and gleeunit.

## What is inside

Driftlog has four data types and a small sync stack.

- `driftlog/register` is a last-writer-wins register.
- `driftlog/rga` is a replicated growable array (list).
- `driftlog/text` is collaborative text over an RGA.
- `driftlog/orset` is an observed-remove set.
- `driftlog/sync` holds the JSON protocol, a store-and-forward server, and a client.
- `driftlog/clock` mints unique, ordered stamps for each replica.

The data types keep their state in memory.
The sync server stores operations and forwards them.
It does not interpret the operations.
One server can serve any document type.

## How it works

A replica owns a clock.
The clock is a Lamport-style counter plus the replica name.
Every edit mints a new stamp.
The stamp identifies the edit forever.
Re-applying an edit is a no-op.

The register keeps the value with the newest stamp.
The RGA orders elements by stamp.
Concurrent edits at one position get one deterministic order.
Deleted elements stay as tombstones.
Their descendants keep their place.

The set mints a fresh stamp for every add.
A remove tombstones the stamps this replica has seen.
Concurrent adds use stamps the remover has not seen.
Those adds survive, so the value stays present.
Re-adding after a remove creates a new stamp.

Merging is commutative, associative, and idempotent.
Merging two replicas gives the same state as merging the reverse order.
Applying the same operations in any order gives the same state.
This is the property the tests check.

## Requirements

- Erlang/OTP 26 or newer
- Gleam 1.18 or newer

Gleam needs Erlang on the `PATH`.
On Windows, add the Gleam install directory to the `PATH`.

## Run the demo

The demo starts a sync server and two replicas.
The replicas edit a document offline.
Then they exchange updates over sockets.
They converge to the same state.

```sh
gleam run
```

Use these commands for the other modes.

```sh
gleam run -- replay fixtures/field-notes.json
gleam run -- replay fixtures/team-tags.json
gleam run -- server 0
```

The `replay` mode runs a fixture through a real server.
The `server` mode runs a standalone server on a port.
Port `0` asks the OS for a free port.

The fixtures directory holds sample data.
It contains three scenarios.
Each scenario has a base document, offline edits, and the expected result.

## Sample output

The demo ends by printing the final state of both replicas.
They show the same text, register, and set.

```
4. Final state
---------------
alice-1
    text     "The quick lazy fox dog"
    register "Driftlog v0.2-final"
    set      ["crdt", "erlang", "gleam"]
bob-1
    text     "The quick lazy fox dog"
    register "Driftlog v0.2-final"
    set      ["crdt", "erlang", "gleam"]
Result: converged to the expected state.
```

## Use the library

Driftlog is a library. It is not yet on Hex.
Use a path dependency to import it from a local checkout.

```toml
[dependencies]
driftlog = { path = "../driftlog" }
```

Create a document on two replicas.

```gleam
import driftlog/text

let alice = text.new("laptop-1")
let #(alice, _) = text.insert_string(alice, 0, "Hello world")

let bob = text.merge(text.new("phone-1"), alice)
let #(bob, _) = text.insert_string(bob, 5, " brave")

let merged = text.merge(alice, bob)
text.read(merged) // "Hello brave world"
```

Create a shared set.

```gleam
import driftlog/orset

let alice = orset.new("laptop-1")
let #(alice, _) = orset.add(alice, "gleam")

let bob = orset.merge(orset.new("phone-1"), alice)
let #(bob, _) = orset.add(bob, "erlang")

let merged = orset.merge(alice, bob)
orset.to_list(merged) // members from both replicas
```

Give each running replica a unique name.
Use a device id or a random string.
Two replicas with the same name could mint the same stamp.

## Sync

A peer sends a request to the server.
The request holds the replica name, the room, a cursor, and new operations.
The room names the document.
The cursor is the number of operations the replica has seen.
The server stores new operations.
It forwards the operations the replica has not seen.
The response holds the forwarded operations and the new cursor.

Operations carry a stable id.
The server drops duplicates.
A client can apply an operation twice without changing its state.

The wire format is newline-delimited JSON.
Each exchange is one request and one response.

## Sync server

Run a standalone server.

```sh
gleam run -- server 0
```

The server prints its port.
Clients connect to `127.0.0.1` on that port.
The server keeps operations in memory.
It is for local development and demonstrations.

## Test

Run the test suite.

```sh
gleam test
```

The suite has 72 tests and they all pass.
It covers the data types and the merge properties.
It also runs real socket exchanges against an in-memory server.
All tests are deterministic.
The random-edit tests use a seeded generator.

## Build

```sh
gleam build
```

Run the formatter check.

```sh
gleam format --check src test
```

## Architecture

```
src/
  driftlog.gleam          entry point and package docs
  driftlog/
    clock.gleam           stamps and logical clocks
    register.gleam        last-writer-wins register
    rga.gleam             replicated growable array
    text.gleam            collaborative text
    orset.gleam           observed-remove set
    sync/
      protocol.gleam      JSON wire protocol
      net.gleam           socket wrapper around gen_tcp
      client.gleam        one sync round trip
      server.gleam        store-and-forward server actor
      peer.gleam          a replica actor with documents
      scenario.gleam      scripted edit scenarios
  driftlog_demo.gleam     the demo command line
  driftlog_net_ffi.erl    gen_tcp external functions
test/                     unit and property tests
fixtures/                 sample scenarios
```

## Roadmap

Complete in 0.2.0:

- Add an observed-remove set (`driftlog/orset`).
- Carry set operations over the sync protocol and the peer.

Remaining:

- Version 0.2: add delta state exchange to the server.
- Version 0.3: persist the server state to disk.
- Version 0.3: add a text API with ranges and undo.
- Version 0.4: add end-to-end encryption for the wire format.

## Limitations

- The server keeps state in memory.
  A restart loses stored operations.
- The server has no authentication.
  It is for local use.
- The RGA materializes the list on every read.
  Very large documents are slower than a delta-based design.
- The text document edits in graphemes.
  It does not handle cursor semantics or selection ranges.
- The register, list, and set sync only string values on the wire.
  Other value types need a custom encoder.

## License

Licensed under the Apache License 2.0.
See the LICENSE file for details.
