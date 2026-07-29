//! expect-error: return type mismatch

// D27: fixed-array indexing observes just like Vec indexing. A declared owned
// return cannot materialize a non-Copy element view.

type Thing { vals: Vec[i32] }

fn take_first(items: &[2]Thing) -> Thing: items[0]

fn main:
    let items = [Thing { vals: Vec.new() }, Thing { vals: Vec.new() }]
    let first = take_first(items)
    assert(first.vals.len() == 0)
