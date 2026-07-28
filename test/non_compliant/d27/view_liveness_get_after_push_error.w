//! D27-NON-COMPLIANT
//! owner-stage: E3
//! required-verdict: compile-error
//! exact-type: `t` is a view into the vec; push may reallocate — use after mutation is rejected (§3.2; TODAY t is a copy in this shape and this compiles — the escalation-watch cell)
//! expected-diagnostic: view may outlive/alias mutation of its origin (§3.2)
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let t = items.get(0)
    items.push(Thing { vals: Vec.new() })
    assert(t.vals.len() == 0)
