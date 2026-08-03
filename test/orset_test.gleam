import driftlog/orset
import gleam/list
import gleam/string
import gleeunit/should

fn sorted(orset: orset.Orset(String)) -> List(String) {
  orset.to_list(orset) |> list.sort(by: string.compare)
}

fn apply_all(
  orset: orset.Orset(String),
  ops: List(orset.OrsetOp(String)),
) -> orset.Orset(String) {
  list.fold(ops, orset, fn(acc, op) { orset.apply(acc, op) })
}

pub fn add_then_read_test() {
  let set = orset.new("a")
  let #(set, _) = orset.add(set, "x")
  let #(set, _) = orset.add(set, "y")
  should.equal(sorted(set), ["x", "y"])
  should.equal(orset.contains(set, "x"), True)
  should.equal(orset.size(set), 2)
}

pub fn adding_the_same_value_keeps_one_value_test() {
  let set = orset.new("a")
  let #(set, _) = orset.add(set, "x")
  let #(set, _) = orset.add(set, "x")
  should.equal(orset.size(set), 1)
  should.equal(orset.raw_size(set), 2)
}

pub fn remove_deletes_the_value_test() {
  let set = orset.new("a")
  let #(set, _) = orset.add(set, "x")
  let #(set, _) = orset.add(set, "y")
  let #(set, ops) = orset.remove(set, "x")
  should.equal(orset.contains(set, "x"), False)
  should.equal(orset.contains(set, "y"), True)
  should.equal(list.length(ops), 1)
}

pub fn re_adding_after_a_remove_comes_back_test() {
  let set = orset.new("a")
  let #(set, _) = orset.add(set, "x")
  let #(set, _) = orset.remove(set, "x")
  let #(set, _) = orset.add(set, "x")
  should.equal(orset.contains(set, "x"), True)
  should.equal(orset.size(set), 1)
}

pub fn a_concurrent_add_survives_a_remove_test() {
  let alice = orset.new("alice-1")
  let #(alice, _) = orset.add(alice, "x")
  let bob = orset.merge(orset.new("bob-1"), alice)
  let #(bob, _) = orset.add(bob, "x")
  let #(alice, _) = orset.remove(alice, "x")
  let merged = orset.merge(alice, bob)
  should.equal(orset.contains(merged, "x"), True)
}

pub fn a_remove_can_precede_its_add_test() {
  let #(_, op_add) = orset.add(orset.new("a"), "x")
  let op_remove = orset.Remove(atom: op_add.atom)
  let bob = orset.new("bob")
  let bob = orset.apply(bob, op_remove)
  let bob = orset.apply(bob, op_add)
  should.equal(orset.contains(bob, "x"), False)
  should.equal(orset.size(bob), 0)
}

pub fn removing_an_absent_value_is_a_no_op_test() {
  let set = orset.new("a")
  let #(set, ops) = orset.remove(set, "missing")
  should.equal(list.length(ops), 0)
  should.equal(orset.size(set), 0)
}

pub fn applying_is_idempotent_test() {
  let set = orset.new("a")
  let #(set, op) = orset.add(set, "x")
  let set = orset.apply(set, op)
  let set = orset.apply(set, op)
  should.equal(orset.size(set), 1)
}

pub fn merge_commutes_test() {
  let a = orset.new("a")
  let #(a, _) = orset.add(a, "x")
  let b = orset.merge(orset.new("b"), a)
  let #(b, _) = orset.add(b, "y")
  let ab = orset.merge(a, b)
  let ba = orset.merge(b, a)
  should.equal(sorted(ab), sorted(ba))
}

pub fn merge_associates_test() {
  let a = orset.new("a")
  let #(a, _) = orset.add(a, "x")
  let b = orset.merge(orset.new("b"), a)
  let #(b, _) = orset.add(b, "y")
  let c = orset.merge(orset.new("c"), b)
  let #(c, _) = orset.add(c, "z")
  let ab_c = orset.merge(orset.merge(a, b), c)
  let a_bc = orset.merge(a, orset.merge(b, c))
  should.equal(sorted(ab_c), sorted(a_bc))
}

pub fn merge_is_idempotent_test() {
  let a = orset.new("a")
  let #(a, _) = orset.add(a, "x")
  let #(a, _) = orset.remove(a, "x")
  let b = orset.merge(orset.new("b"), a)
  let #(b, _) = orset.add(b, "y")
  let merged = orset.merge(a, b)
  let again = orset.merge(merged, b)
  should.equal(sorted(again), sorted(merged))
}

pub fn a_removed_tag_stays_removed_across_a_merge_test() {
  let alice = orset.new("alice-1")
  let #(alice, op_add) = orset.add(alice, "x")
  let #(alice, remove_ops) = orset.remove(alice, "x")
  let bob = orset.merge(orset.new("bob-1"), alice)
  let #(bob, _) = orset.add(bob, "y")
  let out_of_order =
    apply_all(orset.new("c"), list.append(remove_ops, [op_add]))
  let merged = orset.merge(out_of_order, bob)
  should.equal(orset.contains(merged, "x"), False)
  should.equal(orset.contains(merged, "y"), True)
}
