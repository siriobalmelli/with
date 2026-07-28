//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: `items[0]` is the element PLACE; the receiver chain mutates in place (issue-64 cell, respelled)
//! expected-diagnostic: none
//! drop-behavior: vec remains sole owner

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    items[0].vals.push(9)
    assert(items[0].vals.len() == 1)
    assert(items[0].vals.get(0) == 9)
