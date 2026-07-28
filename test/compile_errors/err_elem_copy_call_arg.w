//! expect-error: cannot take ownership of a non-Copy element copied out of a Vec

// D22 §13.6 / #715: a by-value parameter is an owned demand and cannot be
// satisfied by copying a Drop-bearing element out of a Vec.

type Thing { vals: Vec[i32] }

fn consume(t: Thing) -> i64:
    t.vals.len()

fn main:
    var items: Vec[Thing] = Vec.new()
    items.push(Thing { vals: Vec.new() })
    print(int_to_string(consume(items.get(0))))
