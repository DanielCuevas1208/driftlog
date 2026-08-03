//// Replicated growable array (RGA).
////
//// An RGA is a list CRDT. Every element keeps the atom of the element it was
//// inserted after. Siblings are ordered by stamp, newest first. Two replicas
//// that insert at the same place converge to the same order, because the
//// order is a pure function of the set of atoms.
////
//// Deletes use tombstones. A deleted atom stays in the tree so its
//// descendants keep their place. Elements whose parent has not arrived yet
//// are kept, and appear once their parent arrives.
////
//// The final state depends only on the set of operations, not on the order
//// they arrive in. This makes RGA merge commutative, associative, and
//// idempotent, and makes out-of-order delivery safe.

import driftlog/clock.{
  type Atom, type Clock, Atom, advance, head, stamp_compare_desc, tick,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/order.{type Order}
import gleam/pair
import gleam/result
import gleam/set.{type Set}

/// A replicated growable array.
///
/// `elements` maps an atom to its parent atom and its value. `tombstones`
/// holds the atoms that were deleted. `clock` mints stamps for local edits.
pub type Rga(a) {
  Rga(elements: Dict(Atom, #(Atom, a)), tombstones: Set(Atom), clock: Clock)
}

/// An operation on a replicated list.
pub type ListOp(a) {
  /// Insert `value` as a new element after `parent`.
  Insert(atom: Atom, parent: Atom, value: a)
  /// Tombstone the element addressed by `atom`.
  Delete(atom: Atom)
}

/// Create an empty list for a replica.
pub fn new(node: String) -> Rga(a) {
  Rga(elements: dict.new(), tombstones: set.new(), clock: clock.new(node))
}

/// The number of live elements.
pub fn size(list: Rga(a)) -> Int {
  list.length(materialize(list))
}

/// The number of elements, including tombstones.
pub fn raw_size(list: Rga(a)) -> Int {
  dict.size(list.elements)
}

/// The replica name that owns this list.
pub fn node(list: Rga(a)) -> String {
  clock.node(list.clock)
}

/// Insert a value at a live position.
///
/// `index` is the position in the live list. The new element takes the place
/// of the element that currently sits at `index`. Inserting past the end
/// appends.
pub fn insert(list: Rga(a), index: Int, value: a) -> #(Rga(a), ListOp(a)) {
  let parent = anchor_at(list, index)
  let #(clock, stamp) = tick(list.clock)
  let atom = Atom(stamp)
  let elements = dict.insert(list.elements, atom, #(parent, value))
  #(
    Rga(elements:, tombstones: list.tombstones, clock:),
    Insert(atom:, parent:, value:),
  )
}

/// Delete the element at a live position.
///
/// Returns an error when `index` is out of range.
pub fn delete(list: Rga(a), index: Int) -> Result(#(Rga(a), ListOp(a)), Nil) {
  let atoms = list.map(materialize(list), pair.first)
  case at(atoms, index) {
    Ok(atom) -> {
      let tombstones = set.insert(list.tombstones, atom)
      #(
        Rga(elements: list.elements, tombstones:, clock: list.clock),
        Delete(atom:),
      )
      |> Ok
    }
    Error(_) -> Error(Nil)
  }
}

/// Apply a remote operation.
///
/// Applying is idempotent. An insert that already arrived changes nothing.
/// A delete that arrives before its insert is remembered, and the element
/// stays deleted once the insert arrives.
pub fn apply(list: Rga(a), op: ListOp(a)) -> Rga(a) {
  case op {
    Insert(atom:, parent:, value:) -> {
      case dict.get(list.elements, atom) {
        Ok(_) -> list
        Error(_) -> {
          let elements = dict.insert(list.elements, atom, #(parent, value))
          Rga(
            elements:,
            tombstones: list.tombstones,
            clock: advance(list.clock, atom.stamp),
          )
        }
      }
    }
    Delete(atom:) -> {
      let tombstones = set.insert(list.tombstones, atom)
      Rga(elements: list.elements, tombstones:, clock: list.clock)
    }
  }
}

/// Merge two lists.
///
/// The result holds the union of both element sets. A tombstone wins over a
/// live element. On a conflict the merge keeps `a`'s value, so the result
/// does not depend on the order of the arguments. The merged clock keeps the
/// local replica's identity and advances past every stamp it sees.
pub fn merge(a: Rga(x), b: Rga(x)) -> Rga(x) {
  let elements =
    dict.fold(b.elements, a.elements, fn(acc, atom, parent_value) {
      dict.insert(acc, atom, parent_value)
    })
  let tombstones = set.union(a.tombstones, b.tombstones)
  let clock =
    dict.fold(elements, a.clock, fn(acc, atom, _) { advance(acc, atom.stamp) })
  Rga(elements:, tombstones:, clock:)
}

/// The live values in order.
pub fn to_list(list: Rga(a)) -> List(a) {
  list.map(materialize(list), pair.second)
}

/// The live atoms in order.
pub fn to_atoms(list: Rga(a)) -> List(Atom) {
  list.map(materialize(list), pair.first)
}

/// The value at a live position.
pub fn at_position(list: Rga(a), index: Int) -> Result(a, Nil) {
  case at(list.map(materialize(list), pair.second), index) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

/// The atom that a new element at `index` would follow.
///
/// Index 0 anchors to the head. An index past the end anchors to the last
/// live element.
pub fn anchor_at(list: Rga(a), index: Int) -> Atom {
  let atoms = list.map(materialize(list), pair.first)
  case index {
    0 -> head
    _ -> {
      case at(atoms, index - 1) {
        Ok(atom) -> atom
        Error(_) -> {
          case list.last(atoms) {
            Ok(atom) -> atom
            Error(_) -> head
          }
        }
      }
    }
  }
}

/// The live elements, in order.
///
/// Tombstones stay in the traversal so their descendants keep their place,
/// but they are not part of the result.
pub fn materialize(list: Rga(a)) -> List(#(Atom, a)) {
  let children: Dict(Atom, List(#(Atom, a))) =
    dict.fold(list.elements, dict.new(), fn(acc, atom, parent_value) {
      let parent = pair.first(parent_value)
      let element = #(atom, pair.second(parent_value))
      let siblings = result.unwrap(dict.get(acc, parent), [])
      dict.insert(acc, parent, [element, ..siblings])
    })
  walk(list, children, head)
}

fn walk(
  list: Rga(a),
  children: Dict(Atom, List(#(Atom, a))),
  parent: Atom,
) -> List(#(Atom, a)) {
  let siblings =
    result.unwrap(dict.get(children, parent), [])
    |> list.sort(by: compare_elements)
  list.fold(siblings, [], fn(acc, element) {
    let atom = pair.first(element)
    let subtree = walk(list, children, atom)
    case set.contains(list.tombstones, atom) {
      True -> list.append(acc, subtree)
      False -> list.append(acc, list.append([element], subtree))
    }
  })
}

fn compare_elements(a: #(Atom, x), b: #(Atom, x)) -> Order {
  stamp_compare_desc(pair.first(a).stamp, pair.first(b).stamp)
}

fn at(list: List(a), index: Int) -> Result(a, Nil) {
  case list {
    [] -> Error(Nil)
    [head, ..rest] -> {
      case index {
        0 -> Ok(head)
        _ -> at(rest, index - 1)
      }
    }
  }
}
