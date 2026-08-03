import driftlog/clock.{Atom, Stamp}
import driftlog/register
import driftlog/rga.{Delete, Insert}
import driftlog/sync/protocol
import gleeunit/should

fn alice_insert() -> protocol.WireOp {
  protocol.WireInsert(
    atom: Atom(Stamp(3, "alice-1")),
    parent: Atom(Stamp(2, "alice-1")),
    value: "x",
  )
}

fn sample_request() -> protocol.Request {
  protocol.Request(peer: "alice-1", room: "text", cursor: 4, ops: [
    alice_insert(),
    protocol.WireDelete(atom: Atom(Stamp(2, "alice-1"))),
    protocol.WireSet(value: "v", stamp: Stamp(5, "bob-1")),
  ])
}

pub fn requests_round_trip_through_json_test() {
  let request = sample_request()
  let encoded = protocol.encode_request(request)
  let decoded = protocol.decode_request(encoded)
  should.equal(decoded, Ok(request))
}

pub fn responses_round_trip_through_json_test() {
  let response =
    protocol.Response(
      forward: [
        alice_insert(),
        protocol.WireDelete(atom: Atom(Stamp(1, "bob-1"))),
      ],
      cursor: 9,
      stored: 2,
    )
  let encoded = protocol.encode_response(response)
  let decoded = protocol.decode_response(encoded)
  should.equal(decoded, Ok(response))
}

pub fn operation_ids_are_distinct_test() {
  let insert = protocol.op_id(alice_insert())
  let delete =
    protocol.op_id(protocol.WireDelete(atom: Atom(Stamp(3, "alice-1"))))
  let set =
    protocol.op_id(protocol.WireSet(value: "v", stamp: Stamp(3, "alice-1")))
  should.not_equal(insert, delete)
  should.not_equal(insert, set)
  should.not_equal(delete, set)
}

pub fn list_ops_convert_to_wire_and_back_test() {
  let insert =
    Insert(atom: Atom(Stamp(3, "a")), parent: Atom(Stamp(2, "a")), value: "x")
  let wire = protocol.list_op_to_wire(insert)
  should.equal(protocol.wire_to_list_op(wire), Ok(insert))

  let delete = Delete(atom: Atom(Stamp(2, "a")))
  let wire = protocol.list_op_to_wire(delete)
  should.equal(protocol.wire_to_list_op(wire), Ok(delete))
}

pub fn register_ops_convert_to_wire_and_back_test() {
  let op = register.Set(value: "draft", stamp: Stamp(1, "bob-1"))
  let wire = protocol.register_op_to_wire(op)
  should.equal(protocol.wire_to_register_op(wire), Ok(op))
}

pub fn a_set_wire_op_is_not_a_list_op_test() {
  let wire = protocol.WireSet(value: "v", stamp: Stamp(1, "bob-1"))
  should.be_error(protocol.wire_to_list_op(wire))
}

pub fn malformed_lines_are_rejected_test() {
  should.be_error(protocol.decode_request("not json"))
  should.be_error(protocol.decode_response("{\"nope\": 1}"))
}
