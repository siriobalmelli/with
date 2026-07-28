//! D27-NON-COMPLIANT
//! owner-stage: E3
//! required-verdict: compile-error
//! exact-type: typed binding demands owned Thing from a `&Thing` view
//! expected-diagnostic: cannot take ownership of a non-Copy element (D22 §13.6)
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let t: Thing = items.get(0)
    assert(t.vals.len() == 0)
