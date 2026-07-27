//! expect-error: cannot take ownership of a non-Copy field through a borrow

// D22 §13.6 / #730: an owned demand cannot be satisfied from a non-Copy
// field reached through a shared view — that was a silent aliasing
// bit-copy, and the local's drop freed the owner's buffer.

type Outer { v: Vec[i32], n: i32 }

fn main:
    var o = Outer { v: Vec.new(), n: 7 }
    o.v.push(1)
    let stolen = (&o).v
    print(int_to_string(stolen.len()))
