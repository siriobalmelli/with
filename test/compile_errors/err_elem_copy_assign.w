//! expect-error: cannot take ownership of a non-Copy element copied out of a Vec

// D22 §13.6 / #715: assignment into an owned place is an owned demand and
// cannot be satisfied by copying a Drop-bearing element out of a Vec.

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    var slot = Thing { vals: Vec.new() }
    slot = items[0]
    print(int_to_string(slot.vals.len()))
