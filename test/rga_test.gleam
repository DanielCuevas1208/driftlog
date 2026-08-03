import driftlog/rga
import gleeunit/should

fn typed_base() {
  let list = rga.new("a")
  let #(list, _) = rga.insert(list, 0, "a")
  let #(list, _) = rga.insert(list, 1, "b")
  list
}

pub fn insert_appends_at_the_end_test() {
  let list = rga.new("a")
  let #(list, _) = rga.insert(list, 0, "x")
  let #(list, _) = rga.insert(list, 1, "y")
  should.equal(rga.to_list(list), ["x", "y"])
}

pub fn insert_in_the_middle_test() {
  let list = typed_base()
  let #(list, _) = rga.insert(list, 1, "m")
  should.equal(rga.to_list(list), ["a", "m", "b"])
}

pub fn insert_past_the_end_appends_test() {
  let list = typed_base()
  let #(list, _) = rga.insert(list, 99, "z")
  should.equal(rga.to_list(list), ["a", "b", "z"])
}

pub fn delete_uses_a_tombstone_test() {
  let list = typed_base()
  let #(list, _) = rga.delete(list, 0) |> should.be_ok
  should.equal(rga.to_list(list), ["b"])
  should.equal(rga.raw_size(list), 2)
}

pub fn delete_out_of_range_fails_test() {
  let list = typed_base()
  should.be_error(rga.delete(list, 5))
}

pub fn insert_after_delete_keeps_its_position_test() {
  let list = typed_base()
  let #(list, _) = rga.delete(list, 0) |> should.be_ok
  let #(list, _) = rga.insert(list, 0, "z")
  should.equal(rga.to_list(list), ["z", "b"])
}

pub fn concurrent_inserts_converge_test() {
  let alice = rga.new("alice")
  let #(alice, _) = rga.insert(alice, 0, "a")
  let #(alice, _) = rga.insert(alice, 1, "b")
  let bob = rga.merge(rga.new("bob"), alice)

  let #(alice, _) = rga.insert(alice, 1, "X")
  let #(bob, _) = rga.insert(bob, 1, "Y")

  let ab = rga.merge(alice, bob)
  let ba = rga.merge(bob, alice)
  should.equal(rga.to_list(ab), rga.to_list(ba))
}

pub fn a_delete_can_precede_its_insert_test() {
  let alice = rga.new("alice")
  let #(alice, op_a) = rga.insert(alice, 0, "a")
  let #(alice, op_b) = rga.insert(alice, 1, "b")
  let #(_, op_delete_b) = rga.delete(alice, 1) |> should.be_ok

  let bob = rga.new("bob")
  let bob = rga.apply(bob, op_delete_b)
  let bob = rga.apply(bob, op_a)
  let bob = rga.apply(bob, op_b)
  should.equal(rga.to_list(bob), ["a"])
}

pub fn an_element_waits_for_its_parent_test() {
  let alice = rga.new("alice")
  let #(alice, op_a) = rga.insert(alice, 0, "a")
  let #(_alice, op_b) = rga.insert(alice, 1, "b")

  let bob = rga.new("bob")
  let bob = rga.apply(bob, op_b)
  should.equal(rga.to_list(bob), [])
  let bob = rga.apply(bob, op_a)
  should.equal(rga.to_list(bob), ["a", "b"])
}

pub fn applying_is_idempotent_test() {
  let list = rga.new("a")
  let #(list, op) = rga.insert(list, 0, "x")
  let list = rga.apply(list, op)
  let list = rga.apply(list, op)
  should.equal(rga.to_list(list), ["x"])
}

pub fn merge_commutes_test() {
  let a = rga.new("a")
  let #(a, _) = rga.insert(a, 0, "x")
  let #(a, _) = rga.insert(a, 1, "y")
  let b = rga.merge(rga.new("b"), a)
  let #(b, _) = rga.insert(b, 0, "z")

  let ab = rga.merge(a, b)
  let ba = rga.merge(b, a)
  should.equal(rga.to_list(ab), rga.to_list(ba))
}

pub fn merge_is_idempotent_test() {
  let a = rga.new("a")
  let #(a, _) = rga.insert(a, 0, "x")
  let b = rga.merge(rga.new("b"), a)
  let #(b, _) = rga.insert(b, 1, "y")

  let merged = rga.merge(a, b)
  let again = rga.merge(merged, b)
  should.equal(rga.to_list(again), rga.to_list(merged))
}

pub fn merge_associates_test() {
  let a = rga.new("a")
  let #(a, _) = rga.insert(a, 0, "x")
  let b = rga.merge(rga.new("b"), a)
  let #(b, _) = rga.insert(b, 1, "y")
  let c = rga.merge(rga.new("c"), b)
  let #(c, _) = rga.insert(c, 0, "z")

  let ab_c = rga.merge(rga.merge(a, b), c)
  let a_bc = rga.merge(a, rga.merge(b, c))
  should.equal(rga.to_list(ab_c), rga.to_list(a_bc))
}
