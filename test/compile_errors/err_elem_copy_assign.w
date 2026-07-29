//! expect-error: type mismatch in assignment

// D22 §13.6 / D27: assignment into an owned place is an owned demand and
// the exact &Thing element view cannot satisfy it because Thing is not Copy.

type Thing { vals: Vec[i32] }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    var slot = Thing { vals: Vec.new() }
    slot = items[0]
    print(int_to_string(slot.vals.len()))
