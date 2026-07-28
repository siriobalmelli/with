//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-error
//! exact-type: declared owned return demands owned Thing from a view (UNGATED today: compiles, real #715 escape)
//! expected-diagnostic: cannot take ownership of a non-Copy element (D22 §13.6)
//! drop-behavior: n/a

type Thing { vals: Vec[i32] }

fn take_first(items: &Vec[Thing]) -> Thing: items.get(0)

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let t = take_first(&items)
    assert(t.vals.len() == 0)
