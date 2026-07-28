//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: IndexPlace write through the element place
//! expected-diagnostic: none
//! drop-behavior: overwritten element drops once

fn main:
    var xs: Vec[i32] = Vec.new()
    xs.push(1)
    xs[0] = 5
    assert(xs[0] == 5)
