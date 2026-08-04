//// Driftlog: conflict-free replicated data types for offline-first
//// collaboration.
////
//// Driftlog provides four replicated data types and a small sync stack.
//// Two replicas edit the same data offline, then merge without conflicts.
//// Merging is commutative, associative, and idempotent: any delivery order
//// produces the same state.
////
//// The library is organized into focused modules:
////
////  - `driftlog/register`   a last-writer-wins register
////  - `driftlog/rga`        a replicated growable array (list)
////  - `driftlog/text`       collaborative text over an RGA
////  - `driftlog/orset`      an observed-remove set
////  - `driftlog/sync`       JSON protocol, store-and-forward server, client
////
//// A replica owns a clock (`driftlog/clock`) that mints unique, ordered
//// stamps. Give every running replica its own node name, such as the device
//// id. Stamps identify an edit forever, so re-applying an edit is a no-op.
////
//// ## Example
////
//// ```gleam
//// import driftlog/text
////
//// // Alice types a document on her laptop.
//// let alice = text.new("laptop-1")
//// let #(alice, _) = text.insert_string(alice, 0, "Hello world")
////
//// // Bob edits the same document on his phone, offline.
//// let bob = text.new("phone-1")
//// let #(bob, _) = text.insert_string(bob, 5, " brave")
////
//// // They merge. Both end up with "Hello brave world".
//// let merged = text.merge(alice, bob)
//// text.read(merged)
//// ```

import driftlog_demo

/// The version of this release, such as `"0.3.0"`.
pub const version: String = "0.3.0"

/// Format a replica name for logs and demos.
pub fn describe(peer: String) -> String {
  "driftlog " <> version <> " (replica " <> peer <> ")"
}

/// The number of Driftlog data types in this release.
pub const data_type_count: Int = 4

/// The number of sync rooms a peer uses by default.
pub const default_room_count: Int = 3

/// Run the demo when invoked with `gleam run`.
///
/// The full demo lives in the `driftlog_demo` module. Keeping `main` here
/// lets `gleam run` start it without a module flag.
pub fn main() {
  driftlog_demo.main()
}
