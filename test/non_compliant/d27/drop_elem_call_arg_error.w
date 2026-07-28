//! D27-NON-COMPLIANT
//! owner-stage: E3
//! required-verdict: compile-error
//! exact-type: by-value Thing parameter demands owned from a view
//! expected-diagnostic: cannot take ownership of a non-Copy element (D22 §13.6)
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }

fn consume(t: Thing) -> i64: t.vals.len()

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    assert(consume(items.get(0)) == 0)
