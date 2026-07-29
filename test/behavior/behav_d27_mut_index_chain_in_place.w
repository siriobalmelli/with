//! expect-exit: 0

// D27 E1: `items[0]` is the element place; the receiver chain mutates it in
// place while the vec remains the sole owner.

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    items[0].vals.push(9)
    assert(items[0].vals.len() == 1)
    assert(items[0].vals.get(0) == 9)
