//! expect-error: cannot take ownership of a non-Copy field through a borrow

// D22 §13.6 / #735: a by-value parameter is an owned demand and cannot be
// satisfied from a non-Copy field reached through a shared view.

type Outer { v: Vec[i32], n: i32 }

fn takes_owned(x: Vec[i32]) -> i64:
    x.len()

fn main:
    var o = Outer { v: Vec.new(), n: 7 }
    o.v.push(1)
    let r = &o
    print(int_to_string(takes_owned(r.v)))
