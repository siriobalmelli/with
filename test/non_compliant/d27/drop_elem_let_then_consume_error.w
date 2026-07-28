//! D27-NON-COMPLIANT
//! owner-stage: E3
//! required-verdict: compile-error
//! exact-type: the binding holds a view; the LATER consume is the demand (origins through bindings; UNGATED today)
//! expected-diagnostic: cannot take ownership of a non-Copy element (D22 §13.6) at the consume site
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }

fn consume(t: Thing) -> i64: t.vals.len()

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let t = items.get(0)
    assert(consume(t) == 0)
