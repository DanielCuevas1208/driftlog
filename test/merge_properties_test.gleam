import driftlog/register
import driftlog/rga.{type ListOp, type Rga}
import gleam/int
import gleam/list
import gleam/pair
import gleam/string
import gleeunit/should

/// A small deterministic linear congruential generator.
///
/// Tests seed the generator, so every run replays the same edits.
type Rng {
  Rng(state: Int)
}

fn next(rng: Rng, bound: Int) -> #(Rng, Int) {
  let state = rng.state * 1_103_515_245 + 12_345
  let state = state - state / 2_147_483_648 * 2_147_483_648
  let value = state - state / bound * bound
  #(Rng(state:), value)
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

fn alphabet(index: Int) -> String {
  case index {
    0 -> "a"
    1 -> "b"
    _ -> "c"
  }
}

/// Grow a list with random valid edits.
///
/// Every edit is applied to the running replica as it is generated, so the
/// indices stay in range. The returned operations are the whole edit history.
fn grow(
  rng: Rng,
  steps: Int,
  list: Rga(String),
) -> #(Rng, List(ListOp(String))) {
  case steps > 0 {
    False -> #(rng, [])
    True -> {
      let #(rng, kind) = next(rng, 2)
      case kind {
        0 -> {
          let #(rng, index) = next(rng, rga.size(list) + 1)
          let #(rng, char_index) = next(rng, 3)
          let #(list, op) = rga.insert(list, index, alphabet(char_index))
          let #(rng, rest) = grow(rng, steps - 1, list)
          #(rng, [op, ..rest])
        }
        _ -> {
          case rga.size(list) > 0 {
            True -> {
              let #(rng, index) = next(rng, rga.size(list))
              let #(list, op) = rga.delete(list, index) |> should.be_ok
              let #(rng, rest) = grow(rng, steps - 1, list)
              #(rng, [op, ..rest])
            }
            False -> grow(rng, steps - 1, list)
          }
        }
      }
    }
  }
}

fn apply_all(list: Rga(String), ops: List(ListOp(String))) -> Rga(String) {
  list.fold(ops, list, fn(acc, op) { rga.apply(acc, op) })
}

fn apply_all_as_text(ops: List(ListOp(String))) -> String {
  apply_all(rga.new("ref"), ops) |> rga.to_list |> string.concat
}

fn permute(rng: Rng, input: List(a)) -> #(Rng, List(a)) {
  case input {
    [] -> #(rng, [])
    _ -> {
      let #(rng, index) = next(rng, list.length(input))
      let picked = at(input, index) |> should.be_ok
      let remaining =
        list.append(list.take(input, index), list.drop(input, index + 1))
      let #(rng, rest) = permute(rng, remaining)
      #(rng, [picked, ..rest])
    }
  }
}

pub fn applying_ops_in_any_order_converges_test() {
  let #(rng, ops) = grow(Rng(7), 40, rga.new("ref"))
  let golden = apply_all_as_text(ops)

  let #(rng, perm1) = permute(rng, ops)
  let #(rng, perm2) = permute(rng, ops)
  let #(_, perm3) = permute(rng, ops)

  should.equal(apply_all_as_text(perm1), golden)
  should.equal(apply_all_as_text(perm2), golden)
  should.equal(apply_all_as_text(perm3), golden)
}

pub fn state_merge_equals_apply_all_ops_test() {
  let #(_, ops) = grow(Rng(11), 60, rga.new("ref"))
  let golden = apply_all_as_text(ops)

  let #(a_ops, b_ops) =
    list.index_fold(ops, #([], []), fn(acc, op, index) {
      case index % 2 == 0 {
        True -> #(list.append(pair.first(acc), [op]), pair.second(acc))
        False -> #(pair.first(acc), list.append(pair.second(acc), [op]))
      }
    })
  let a = apply_all(rga.new("a"), a_ops)
  let b = apply_all(rga.new("b"), b_ops)
  let merged = rga.merge(a, b)
  let merged_text = rga.to_list(merged) |> string.concat

  should.equal(merged_text, golden)
}

pub fn text_documents_converge_under_any_order_test() {
  let #(rng, ops) = grow(Rng(13), 50, rga.new("ref"))
  let golden = apply_all_as_text(ops)
  let #(_, perm) = permute(rng, ops)
  should.equal(apply_all_as_text(perm), golden)
}

pub fn register_merges_are_deterministic_test() {
  let #(rng, a_ops) = grow_register(Rng(17), 12)
  let #(_, b_ops) = grow_register(rng, 12)

  let a = apply_register_ops(a_ops)
  let b = apply_register_ops(b_ops)
  let ab = register.merge(a, b)
  let ba = register.merge(b, a)
  should.equal(register.read(ab), register.read(ba))

  let again = register.merge(ab, b)
  should.equal(register.read(again), register.read(ab))
}

fn grow_register(
  rng: Rng,
  steps: Int,
) -> #(Rng, List(register.RegisterOp(String))) {
  case steps > 0 {
    False -> #(rng, [])
    True -> {
      let #(rng, value_index) = next(rng, 4)
      let value = "value-" <> int.to_string(value_index)
      let #(_register, op) = register.write(register.new("ref", ""), value)
      let #(rng, rest) = grow_register(rng, steps - 1)
      #(rng, [op, ..rest])
    }
  }
}

fn apply_register_ops(
  ops: List(register.RegisterOp(String)),
) -> register.Register(String) {
  list.fold(ops, register.new("ref", ""), fn(acc, op) {
    register.apply(acc, op)
  })
}
