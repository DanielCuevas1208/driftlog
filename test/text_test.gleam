import driftlog/text
import gleeunit/should

fn base(node: String) {
  let document = text.new(node)
  let #(document, _) = text.insert_string(document, 0, "Hello world")
  document
}

pub fn insert_string_round_trips_test() {
  let document = text.new("a")
  let #(document, _) = text.insert_string(document, 0, "Hello")
  should.equal(text.read(document), "Hello")
}

pub fn insert_string_in_the_middle_test() {
  let document = base("a")
  let #(document, _) = text.insert_string(document, 5, " brave")
  should.equal(text.read(document), "Hello brave world")
}

pub fn insert_string_appends_test() {
  let document = base("a")
  let #(document, _) = text.insert_string(document, 11, "!")
  should.equal(text.read(document), "Hello world!")
}

pub fn delete_range_removes_graphemes_test() {
  let document = base("a")
  let #(document, _) = text.delete_range(document, 0, 5) |> should.be_ok
  should.equal(text.read(document), " world")
}

pub fn delete_range_out_of_bounds_fails_test() {
  let document = base("a")
  let result = text.delete_range(document, 11, 5)
  should.be_error(result)
}

pub fn unicode_graphemes_stay_whole_test() {
  // "e" plus a combining acute accent is one grapheme.
  let document = text.new("a")
  let #(document, _) = text.insert_string(document, 0, "e\u{0301}x")
  should.equal(text.size(document), 2)
  should.equal(text.read(document), "e\u{0301}x")
}

pub fn merge_produces_one_string_either_way_test() {
  let a = base("a")
  let b = base("b")
  let #(a, _) = text.insert_string(a, 0, "!")
  let #(b, _) = text.insert_string(b, 11, "?")

  let ab = text.merge(a, b)
  let ba = text.merge(b, a)
  should.equal(text.read(ab), text.read(ba))
}

pub fn concurrent_edits_at_one_position_converge_test() {
  let a = base("alice")
  let b = text.merge(text.new("bob"), a)
  let #(a, _) = text.insert_string(a, 5, "X")
  let #(b, _) = text.insert_string(b, 5, "Y")

  let ab = text.merge(a, b)
  let ba = text.merge(b, a)
  should.equal(text.read(ab), text.read(ba))
}

pub fn a_delete_can_precede_its_insert_test() {
  let a = base("alice")
  let #(a, _) = text.delete_range(a, 0, 5) |> should.be_ok
  // Move the tombstones and inserts across a merge, then check the outcome.
  let b = text.merge(text.new("bob"), a)
  should.equal(text.read(b), " world")
}

pub fn merge_is_idempotent_test() {
  let a = base("alice")
  let #(a, _) = text.insert_string(a, 5, "X")
  let b = text.merge(text.new("bob"), a)
  let merged = text.merge(a, b)
  let again = text.merge(merged, b)
  should.equal(text.read(again), text.read(merged))
}

pub fn readme_example_test() {
  let alice = text.new("laptop-1")
  let #(alice, _) = text.insert_string(alice, 0, "Hello world")

  let bob = text.merge(text.new("phone-1"), alice)
  let #(bob, _) = text.insert_string(bob, 5, " brave")

  let merged = text.merge(alice, bob)
  should.equal(text.read(merged), "Hello brave world")
}
