//! D27-NON-COMPLIANT
//! owner-stage: E3
//! required-verdict: compile-error
//! exact-type: struct-literal field demands owned from a view
//! expected-diagnostic: cannot take ownership of a non-Copy element (D22 §13.6)
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }
type Holder { t: Thing }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let h = Holder { t: items.get(0) }
    assert(h.t.vals.len() == 0)
