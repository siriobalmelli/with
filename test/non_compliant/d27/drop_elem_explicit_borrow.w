//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: `&items[0]` is the explicit spelling of the same view
//! expected-diagnostic: none
//! drop-behavior: vec remains sole owner

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let t = &items[0]
    assert(t.vals.len() == 0)
