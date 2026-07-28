//! D27-NON-COMPLIANT
//! owner-stage: E3
//! required-verdict: compile-error
//! exact-type: assignment into an owned place demands owned from a view
//! expected-diagnostic: cannot take ownership of a non-Copy element (D22 §13.6)
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    var slot = Thing { vals: Vec.new() }
    slot = items[0]
    assert(slot.vals.len() == 0)
