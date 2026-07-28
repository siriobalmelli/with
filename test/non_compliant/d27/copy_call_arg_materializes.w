//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: by-value i32 parameter demands owned; contextual Copy materializes
//! expected-diagnostic: none
//! drop-behavior: vec drops once

fn add_one(n: i32) -> i32: n + 1

fn main:
    var xs: Vec[i32] = Vec.new()
    xs.push(6)
    assert(add_one(xs.get(0)) == 7)
