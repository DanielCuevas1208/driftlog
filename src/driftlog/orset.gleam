//// Observed-remove set (OR-set).
////
//// An OR-set stores one tag per add. A tag is a unique atom. Removing a
//// value removes the tags this replica has seen. It does not remove tags
//// that other replicas added concurrently. Those tags survive, so the value
//// stays present. Merge takes the union of both tag sets.
////
//// Every add mints a fresh tag. Re-adding a value after a remove creates a
//// new tag, so the value comes back. Removed tags stay as tombstones. A
//// remove that arrives before its add still wins, so delivery order does not
//// change the final set.

import driftlog/clock.{type Atom, type Clock, Atom, advance, tick}
import gleam/dict.{type Dict}
import gleam/list
import gleam/set.{type Set}

/// An observed-remove set.
///
/// `elements` maps a tag to its value. `removed` holds the tags that were
/// removed. `clock` mints tags for local adds.
pub type Orset(a) {
  Orset(elements: Dict(Atom, a), removed: Set(Atom), clock: Clock)
}

/// An operation on a set.
pub type OrsetOp(a) {
  /// Add `value` under a fresh tag.
  Add(atom: Atom, value: a)
  /// Tombstone the tag addressed by `atom`.
  Remove(atom: Atom)
}

/// Create an empty set for a replica.
pub fn new(node: String) -> Orset(a) {
  Orset(elements: dict.new(), removed: set.new(), clock: clock.new(node))
}

/// The replica name that owns this set.
pub fn node(orset: Orset(a)) -> String {
  clock.node(orset.clock)
}

/// Add a value.
///
/// The add gets a fresh tag. The returned operation is what a replica sends
/// to its peers.
pub fn add(orset: Orset(a), value: a) -> #(Orset(a), OrsetOp(a)) {
  let #(clock, stamp) = tick(orset.clock)
  let atom = Atom(stamp)
  let elements = dict.insert(orset.elements, atom, value)
  #(Orset(elements:, removed: orset.removed, clock:), Add(atom:, value:))
}

/// Remove a value.
///
/// Removal tombstones every live tag of the value that this replica can see.
/// Concurrent adds from other replicas use tags this replica has not seen, so
/// they survive. The returned operations are what a replica sends to peers.
pub fn remove(orset: Orset(a), value: a) -> #(Orset(a), List(OrsetOp(a))) {
  let live_tags =
    dict.filter(orset.elements, fn(_atom, current) { current == value })
  let elements =
    dict.fold(live_tags, orset.elements, fn(acc, atom, _) {
      dict.delete(acc, atom)
    })
  let removed =
    dict.fold(live_tags, orset.removed, fn(acc, atom, _) {
      set.insert(acc, atom)
    })
  let ops = list.map(dict.keys(live_tags), Remove)
  #(Orset(elements:, removed:, clock: orset.clock), ops)
}

/// Apply a remote operation.
///
/// Applying is idempotent. A remove that tombstones a tag wins over a later
/// add of the same tag.
pub fn apply(orset: Orset(a), op: OrsetOp(a)) -> Orset(a) {
  case op {
    Add(atom:, value:) -> {
      case set.contains(orset.removed, atom) {
        True -> orset
        False -> {
          let elements = dict.insert(orset.elements, atom, value)
          Orset(
            elements:,
            removed: orset.removed,
            clock: advance(orset.clock, atom.stamp),
          )
        }
      }
    }
    Remove(atom:) -> {
      let elements = dict.delete(orset.elements, atom)
      let removed = set.insert(orset.removed, atom)
      Orset(elements:, removed:, clock: orset.clock)
    }
  }
}

/// Merge two sets.
///
/// The result holds the union of both tag sets. A removed tag stays removed,
/// even when the other replica still has it live. The merged clock keeps the
/// local replica's identity and advances past every tag it sees.
pub fn merge(a: Orset(x), b: Orset(x)) -> Orset(x) {
  let elements =
    dict.fold(b.elements, a.elements, fn(acc, atom, value) {
      dict.insert(acc, atom, value)
    })
  let removed = set.union(a.removed, b.removed)
  let clock =
    dict.fold(elements, a.clock, fn(acc, atom, _) { advance(acc, atom.stamp) })
  Orset(elements:, removed:, clock:)
}

/// The live values as a set.
pub fn read(orset: Orset(a)) -> Set(a) {
  dict.fold(orset.elements, set.new(), fn(acc, atom, value) {
    case set.contains(orset.removed, atom) {
      True -> acc
      False -> set.insert(acc, value)
    }
  })
}

/// The live values.
///
/// Set members have no intrinsic order. Sort the result at the call site for
/// a stable, readable order in logs and the demo.
pub fn to_list(orset: Orset(a)) -> List(a) {
  set.to_list(read(orset))
}

/// True when the value is present.
pub fn contains(orset: Orset(a), value: a) -> Bool {
  set.contains(read(orset), value)
}

/// The number of live values.
pub fn size(orset: Orset(a)) -> Int {
  set.size(read(orset))
}

/// The number of live tags.
///
/// Concurrent adds of one value create several tags. This counts every tag
/// that survives, so it can be larger than `size`.
pub fn raw_size(orset: Orset(a)) -> Int {
  dict.fold(orset.elements, 0, fn(acc, atom, _) {
    case set.contains(orset.removed, atom) {
      True -> acc
      False -> acc + 1
    }
  })
}
