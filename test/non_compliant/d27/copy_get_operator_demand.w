//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: `xs.get(0)` is `&i32`; operator position materializes
//! expected-diagnostic: none
//! drop-behavior: vec drops once

fn main:
    var xs: Vec[i32] = Vec.new()
    xs.push(41)
    assert(xs.get(0) + 1 == 42)
