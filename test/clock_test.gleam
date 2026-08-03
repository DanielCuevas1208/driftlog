import driftlog/clock
import gleam/order.{Lt}
import gleeunit/should

pub fn tick_increases_the_counter_test() {
  let clock = clock.new("a")
  let #(clock1, stamp1) = clock.tick(clock)
  let #(_, stamp2) = clock.tick(clock1)
  should.equal(stamp1.logical, 1)
  should.equal(stamp2.logical, 2)
  should.equal(stamp2.node, "a")
}

pub fn stamps_from_one_replica_are_totally_ordered_test() {
  let clock = clock.new("a")
  let #(clock, stamp1) = clock.tick(clock)
  let #(_, stamp2) = clock.tick(clock)
  should.equal(clock.stamp_compare(stamp1, stamp2), Lt)
}

pub fn the_head_sorts_before_real_stamps_test() {
  let #(_, stamp) = clock.tick(clock.new("b"))
  should.equal(clock.stamp_compare(clock.head.stamp, stamp), Lt)
}

pub fn the_replica_name_breaks_counter_ties_test() {
  should.equal(
    clock.stamp_compare(clock.Stamp(1, "alice-1"), clock.Stamp(1, "bob-1")),
    Lt,
  )
}

pub fn stamp_ids_are_stable_and_unique_test() {
  let id = clock.stamp_id(clock.Stamp(7, "alice-1"))
  should.equal(id, "alice-1:7")
  let other = clock.stamp_id(clock.Stamp(8, "alice-1"))
  should.not_equal(id, other)
}

pub fn atom_ids_match_stamp_ids_test() {
  let atom = clock.Atom(clock.Stamp(3, "bob-1"))
  should.equal(clock.atom_id(atom), "bob-1:3")
}
