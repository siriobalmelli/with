//! expect-error: cannot take ownership of a non-Copy element copied out of a Vec

// D22 §13.6 / #715: a struct-literal field is an owned demand and cannot be
// satisfied by copying a Drop-bearing element out of a Vec.

type Thing { vals: Vec[i32] }
type Holder { t: Thing }

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    let h = Holder { t: items.get(0) }
    print(int_to_string(h.t.vals.len()))
