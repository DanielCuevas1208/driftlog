//// Last-writer-wins register.
////
//// A register holds one value and the stamp of the write that produced it.
//// Two registers merge by keeping the value with the newer stamp. Equal
//// stamps are broken by replica name, so the merge is deterministic.
////
//// Merge is commutative, associative, and idempotent. Applying a write that
//// is older than the stored value is a no-op.

import driftlog/clock.{type Clock, type Stamp, advance, stamp_compare, tick}
import gleam/order.{Lt}
import gleam/pair

/// A last-writer-wins register.
///
/// `current` is the winning value together with the stamp of its write.
/// `clock` mints stamps for future writes on this replica.
pub type Register(a) {
  Register(current: #(a, Stamp), clock: Clock)
}

/// The operation of writing a value to a register.
pub type RegisterOp(a) {
  Set(value: a, stamp: Stamp)
}

/// Create an empty register with `default` as its initial value.
pub fn new(node: String, default value: a) -> Register(a) {
  Register(current: #(value, clock.head.stamp), clock: clock.new(node))
}

/// Read the current value.
pub fn read(register: Register(a)) -> a {
  pair.first(register.current)
}

/// Read the stamp of the current value.
pub fn stamp(register: Register(a)) -> Stamp {
  pair.second(register.current)
}

/// Write a new value.
///
/// The write gets the next stamp from the register clock. The returned
/// operation is what a replica sends to its peers.
pub fn write(register: Register(a), value: a) -> #(Register(a), RegisterOp(a)) {
  let #(clock, new_stamp) = tick(register.clock)
  let op = Set(value:, stamp: new_stamp)
  #(Register(current: #(value, new_stamp), clock:), op)
}

/// Apply a remote write.
///
/// Applying is idempotent. A write that loses to the stored stamp changes
/// nothing.
pub fn apply(register: Register(a), op: RegisterOp(a)) -> Register(a) {
  case op {
    Set(value:, stamp:) -> {
      case stamp_compare(stamp, pair.second(register.current)) {
        Lt -> register
        _ ->
          Register(
            current: #(value, stamp),
            clock: advance(register.clock, stamp),
          )
      }
    }
  }
}

/// Merge two registers.
///
/// The value with the newer stamp wins. On a tie the merge keeps `a`'s value,
/// so the result does not depend on the order of the arguments.
pub fn merge(a: Register(a), b: Register(a)) -> Register(a) {
  let a_stamp = pair.second(a.current)
  let b_stamp = pair.second(b.current)
  case stamp_compare(a_stamp, b_stamp) {
    Lt -> Register(current: b.current, clock: advance(a.clock, b_stamp))
    _ -> Register(current: a.current, clock: advance(a.clock, a_stamp))
  }
}
