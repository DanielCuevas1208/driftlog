import driftlog
import gleeunit
import gleeunit/should

pub fn release_metadata_matches_scope_test() {
  should.equal(driftlog.version, "0.3.0")
  should.equal(driftlog.data_type_count, 4)
  should.equal(driftlog.default_room_count, 3)
}

pub fn main() {
  gleeunit.main()
}
