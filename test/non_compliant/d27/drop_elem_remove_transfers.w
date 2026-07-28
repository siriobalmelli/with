//! D27-NON-COMPLIANT
//! owner-stage: E2
//! required-verdict: compile-and-run
//! exact-type: `remove(0)` produces owned Thing; vec no longer owns it
//! expected-diagnostic: none
//! drop-behavior: element drops exactly once, via the binding, not the vec

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let t = items.remove(0)
    assert(t.vals.len() == 0)
    assert(items.len() == 0)
