//! expect-error: type mismatch in assignment

// D27 E3: assignment to an owned Thing place cannot consume an element view.

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    var slot = Thing { vals: Vec.new() }
    slot = items[0]
    assert(slot.vals.len() == 0)
