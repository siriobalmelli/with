//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: runs
//! exact-type: the annotation demands what it says — `var off: i32` materializes the
//! Copy element at initialization; reassignment mutates owned scratch storage
//! expected-diagnostic: none
//! drop-behavior: n/a (Copy)

fn main:
    var xs: Vec[i32] = Vec.new()
    xs.push(50)
    var off: i32 = xs.get(0)
    off = off + 1
    assert(off == 51)
    xs.push(3)
    var pos: i32 = xs.get(1)
    pos = pos + 2
    assert(pos == 5)
