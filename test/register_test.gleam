import driftlog/register
import gleeunit/should

pub fn write_then_read_test() {
  let register = register.new("a", "")
  let #(register, op) = register.write(register, "hello")
  should.equal(register.read(register), "hello")
  should.equal(op.stamp.node, "a")
}

pub fn the_newer_write_wins_test() {
  let #(a, _) = register.write(register.new("a", ""), "first")
  let #(a, _) = register.write(a, "second")
  let b = register.new("b", "")
  let merged = register.merge(a, b)
  should.equal(register.read(merged), "second")
}

pub fn applying_is_idempotent_test() {
  let register = register.new("a", "")
  let #(register, op) = register.write(register, "x")
  let register = register.apply(register, op)
  let register = register.apply(register, op)
  should.equal(register.read(register), "x")
}

pub fn an_older_write_does_not_apply_test() {
  let register = register.new("a", "")
  let #(register, old_op) = register.write(register, "old")
  let #(register, _new_op) = register.write(register, "new")
  let register = register.apply(register, old_op)
  should.equal(register.read(register), "new")
}

pub fn merge_commutes_test() {
  let #(a, _) = register.write(register.new("a", ""), "from-a")
  let #(b, _) = register.write(register.new("b", ""), "from-b")
  let ab = register.merge(a, b)
  let ba = register.merge(b, a)
  should.equal(register.read(ab), register.read(ba))
}

pub fn merge_associates_test() {
  let #(a, _) = register.write(register.new("a", ""), "x")
  let #(b, _) = register.write(register.new("b", ""), "y")
  let #(c, _) = register.write(register.new("c", ""), "z")
  let ab_c = register.merge(register.merge(a, b), c)
  let a_bc = register.merge(a, register.merge(b, c))
  should.equal(register.read(ab_c), register.read(a_bc))
}

pub fn merge_is_idempotent_test() {
  let #(a, _) = register.write(register.new("a", ""), "x")
  let #(b, _) = register.write(register.new("b", ""), "y")
  let merged = register.merge(a, b)
  let again = register.merge(merged, b)
  should.equal(register.read(again), register.read(merged))
}

pub fn a_tie_is_broken_deterministically_test() {
  let #(a, _) = register.write(register.new("a", ""), "tie-a")
  let #(b, _) = register.write(register.new("b", ""), "tie-b")
  let ab = register.merge(a, b)
  let ba = register.merge(b, a)
  should.equal(register.read(ab), register.read(ba))
}

pub fn an_empty_register_loses_to_any_write_test() {
  let #(a, _) = register.write(register.new("a", ""), "value")
  let empty = register.new("b", "")
  let merged = register.merge(a, empty)
  should.equal(register.read(merged), "value")
}
