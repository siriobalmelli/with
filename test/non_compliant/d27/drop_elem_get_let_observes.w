//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: `t` binds `&Thing`
//! expected-diagnostic: none
//! drop-behavior: vec remains sole owner; element drops once via the vec

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let t = items.get(0)
    assert(t.vals.len() == 0)
    assert(items.len() == 1)
