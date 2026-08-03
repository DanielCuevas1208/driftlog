//// Collaborative text.
////
//// A text document is an RGA whose elements are single graphemes. Editing
//// works in positions, as a user types. Merging two documents produces the
//// same string on every replica.
////
//// Unicode graphemes are the unit of editing, so combining marks stay with
//// the letter they modify.

import driftlog/rga.{type ListOp, type Rga}
import gleam/list
import gleam/string

/// A collaborative text document.
pub type Text {
  Text(rga: Rga(String))
}

/// An operation on a text document.
///
/// Every operation is a single-grapheme list operation. Sync code applies
/// them to a document in any order.
pub type TextOp =
  ListOp(String)

/// Create an empty document for a replica.
pub fn new(node: String) -> Text {
  Text(rga: rga.new(node))
}

/// The document as a string.
pub fn read(text: Text) -> String {
  text.rga |> rga.to_list |> string.concat
}

/// The number of live graphemes.
pub fn size(text: Text) -> Int {
  rga.size(text.rga)
}

/// Insert one grapheme at a position.
///
/// Returns an error when `grapheme` is not exactly one grapheme. Use
/// `insert_string` to insert several graphemes at once.
pub fn insert(
  text: Text,
  index: Int,
  grapheme: String,
) -> Result(#(Text, TextOp), Nil) {
  case string.to_graphemes(grapheme) {
    [only] -> {
      let #(rga, op) = rga.insert(text.rga, index, only)
      #(Text(rga:), op)
      |> Ok
    }
    _ -> Error(Nil)
  }
}

/// Insert a string at a position.
///
/// The string becomes a run of graphemes, one element per grapheme. This is
/// how a user's typing is captured: every character is addressable.
pub fn insert_string(
  text: Text,
  index: Int,
  value: String,
) -> #(Text, List(TextOp)) {
  list.index_fold(string.to_graphemes(value), #(text, []), fn(acc, grapheme, i) {
    let #(text, ops) = acc
    let #(rga, op) = rga.insert(text.rga, index + i, grapheme)
    #(Text(rga:), list.append(ops, [op]))
  })
}

/// Delete the grapheme at a position.
pub fn delete(text: Text, index: Int) -> Result(#(Text, TextOp), Nil) {
  case rga.delete(text.rga, index) {
    Ok(#(rga, op)) -> Ok(#(Text(rga:), op))
    Error(_) -> Error(Nil)
  }
}

/// Delete a run of graphemes starting at a position.
pub fn delete_range(
  text: Text,
  start: Int,
  count: Int,
) -> Result(#(Text, List(TextOp)), Nil) {
  list.fold(list.repeat(Nil, times: count), Ok(#(text, [])), fn(acc, _) {
    case acc {
      Ok(#(text, ops)) -> {
        case delete(text, start) {
          Ok(#(text, op)) -> Ok(#(text, list.append(ops, [op])))
          Error(_) -> Error(Nil)
        }
      }
      Error(_) -> Error(Nil)
    }
  })
}

/// Apply a remote operation.
pub fn apply(text: Text, op: TextOp) -> Text {
  Text(rga: rga.apply(text.rga, op))
}

/// Merge two documents.
pub fn merge(a: Text, b: Text) -> Text {
  Text(rga: rga.merge(a.rga, b.rga))
}
