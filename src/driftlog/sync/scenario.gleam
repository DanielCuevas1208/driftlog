//// A scripted scenario of offline edits.
////
//// A scenario describes a base document, the offline edits each replica
//// makes, and the expected converged state. The demo replays a scenario
//// through a real sync server. Tests reuse the same type.
////
//// A fixture file is one JSON document:
////
//// ```json
//// {
////   "title": "Field notes merge",
////   "base": "The quick brown fox",
////   "replicas": [
////     {
////       "name": "alice-1",
////       "text": [{ "op": "insert", "index": 16, "value": "lazy " }],
////       "register": [{ "op": "set", "value": "Driftlog v0.1" }],
////       "set": [{ "op": "add", "value": "gleam" }]
////     }
////   ],
////   "expected": { "text": "...", "register": "...", "set": ["gleam"] }
//// }
//// ```
////
//// Edit indices are positions in the document at the moment the edit runs,
//// as a user would type them. The `set` fields are optional. A fixture
//// without them behaves as an empty set.

import gleam/dynamic/decode
import gleam/json
import gleam/result

/// One offline edit a replica makes.
pub type Edit {
  EditInsert(index: Int, value: String)
  EditDelete(index: Int, count: Int)
  EditSetRegister(value: String)
  EditAdd(value: String)
  EditRemove(value: String)
}

/// One replica and its offline edits.
pub type Replica {
  Replica(name: String, text: List(Edit), register: List(Edit), set: List(Edit))
}

/// A full scenario.
pub type Scenario {
  Scenario(
    title: String,
    base: String,
    replicas: List(Replica),
    expected_text: String,
    expected_register: String,
    expected_set: List(String),
  )
}

/// Decode a scenario from a JSON fixture.
pub fn decode(data: String) -> Result(Scenario, String) {
  json.parse(from: data, using: scenario_decoder())
  |> result.map_error(fn(_) { "invalid scenario fixture" })
}

fn scenario_decoder() -> decode.Decoder(Scenario) {
  use title <- decode.field("title", decode.string)
  use base <- decode.field("base", decode.string)
  use replicas <- decode.field("replicas", decode.list(of: replica_decoder()))
  use expected <- decode.field("expected", expected_decoder())
  let #(expected_text, expected_register, expected_set) = expected
  decode.success(Scenario(
    title:,
    base:,
    replicas:,
    expected_text:,
    expected_register:,
    expected_set:,
  ))
}

fn expected_decoder() -> decode.Decoder(#(String, String, List(String))) {
  use text <- decode.field("text", decode.string)
  use register <- decode.field("register", decode.string)
  use set <- decode.optional_field("set", [], decode.list(of: decode.string))
  decode.success(#(text, register, set))
}

fn replica_decoder() -> decode.Decoder(Replica) {
  use name <- decode.field("name", decode.string)
  use text <- decode.field("text", decode.list(of: edit_decoder()))
  use register <- decode.field("register", decode.list(of: edit_decoder()))
  use set <- decode.optional_field("set", [], decode.list(of: edit_decoder()))
  decode.success(Replica(name:, text:, register:, set:))
}

fn edit_decoder() -> decode.Decoder(Edit) {
  use op <- decode.field("op", decode.string)
  case op {
    "insert" -> {
      use index <- decode.field("index", decode.int)
      use value <- decode.field("value", decode.string)
      decode.success(EditInsert(index:, value:))
    }
    "delete" -> {
      use index <- decode.field("index", decode.int)
      use count <- decode.field("count", decode.int)
      decode.success(EditDelete(index:, count:))
    }
    "set" -> {
      use value <- decode.field("value", decode.string)
      decode.success(EditSetRegister(value:))
    }
    "add" -> {
      use value <- decode.field("value", decode.string)
      decode.success(EditAdd(value:))
    }
    "remove" -> {
      use value <- decode.field("value", decode.string)
      decode.success(EditRemove(value:))
    }
    _ -> decode.failure(EditInsert(index: 0, value: ""), "edit op kind")
  }
}
