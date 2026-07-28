//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: typed binding demands owned i32; contextual Copy materializes; vec unaffected
//! expected-diagnostic: none
//! drop-behavior: vec drops once

fn main:
    var xs: Vec[i32] = Vec.new()
    xs.push(7)
    let n: i32 = xs[0]
    assert(n == 7)
    assert(xs.len() == 1)
