//// Logical clocks and stamps for Driftlog.
////
//// Every replica owns one clock. The clock hands out stamps that are unique
//// to that replica and totally ordered. A stamp is the pair of a per-replica
//// counter and the replica name. Merge keeps the clock ahead of every stamp
//// it has seen, so a replica never reuses a stamp after a merge.

import gleam/int
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/string

/// A logical clock that produces unique, ordered stamps for one replica.
pub type Clock {
  Clock(node: String, logical: Int)
}

/// A Lamport-style stamp: a per-replica counter plus the replica name.
///
/// Two stamps from the same replica are ordered by counter. Stamps from
/// different replicas are ordered by replica name when their counters match.
pub type Stamp {
  Stamp(logical: Int, node: String)
}

/// The atom that anchors the start of a replicated list.
///
/// Its stamp sorts before every real stamp, so it always stays first.
pub const head: Atom = Atom(Stamp(0, ""))

/// An element address inside a replicated list.
///
/// An atom identifies one element forever, across every replica.
pub type Atom {
  Atom(stamp: Stamp)
}

/// Create a clock for a replica.
///
/// `node` must be unique to the running replica. Two replicas that share a
/// node could mint the same stamp.
pub fn new(node: String) -> Clock {
  Clock(node:, logical: 0)
}

/// Return the node name of the clock.
pub fn node(clock: Clock) -> String {
  clock.node
}

/// Advance the clock and return the next stamp.
pub fn tick(clock: Clock) -> #(Clock, Stamp) {
  let logical = clock.logical + 1
  #(Clock(node: clock.node, logical:), Stamp(logical:, node: clock.node))
}

/// Total order on stamps, ascending.
///
/// The counter comes first. The replica name breaks a counter tie.
pub fn stamp_compare(a: Stamp, b: Stamp) -> Order {
  case int.compare(a.logical, b.logical) {
    Eq -> string.compare(a.node, b.node)
    other -> other
  }
}

/// Total order on stamps, descending.
///
/// Newer stamps come first. This is the order siblings keep in a list.
pub fn stamp_compare_desc(a: Stamp, b: Stamp) -> Order {
  case stamp_compare(a, b) {
    Lt -> Gt
    Gt -> Lt
    Eq -> Eq
  }
}

/// A stable identifier for a stamp, such as `"alice-1:7"`.
pub fn stamp_id(stamp: Stamp) -> String {
  stamp.node <> ":" <> int.to_string(stamp.logical)
}

/// A stable identifier for an atom, such as `"alice-1:7"`.
pub fn atom_id(atom: Atom) -> String {
  stamp_id(atom.stamp)
}

/// Keep a clock ahead of a stamp.
///
/// The next tick from this clock sorts after the stamp. This is how a replica
/// avoids reusing a counter after it merges remote state.
pub fn advance(clock: Clock, stamp: Stamp) -> Clock {
  Clock(node: clock.node, logical: int.max(clock.logical, stamp.logical))
}
