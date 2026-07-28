//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: `n` binds `&i32`; the operator demand materializes an owned i32
//! expected-diagnostic: none
//! drop-behavior: vec drops once; no element drop

fn main:
    var xs: Vec[i32] = Vec.new()
    xs.push(7)
    let n = xs[0]
    assert(n + 1 == 8)
    assert(xs.len() == 1)
