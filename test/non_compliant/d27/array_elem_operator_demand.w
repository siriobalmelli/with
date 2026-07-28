//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-and-run
//! exact-type: fixed-array element read is a view; operator demand materializes
//! expected-diagnostic: none
//! drop-behavior: array drops once

fn main:
    let arr = [10, 20]
    assert(arr[1] + 1 == 21)
