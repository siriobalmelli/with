//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-error
//! exact-type: `items.get(0)` is a read-only view; mutating through it is rejected (TODAY this aliases in place — the issue-64 accident D27 respells to `[i]`)
//! expected-diagnostic: cannot call mutating method through a read-only place (§15.2)
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    items.get(0).vals.push(9)
    assert(items.get(0).vals.len() == 1)
