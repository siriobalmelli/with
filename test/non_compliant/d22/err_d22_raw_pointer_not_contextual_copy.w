//! D22-NON-COMPLIANT
//! owner-stage: 2
//! required-verdict: check-fail at the typed binding
//! exact-type: `raw` is `*const i32`, never `&i32`
//! expected-diagnostic: type mismatch; raw pointers do not contextually materialize
//! origin-set: not applicable; raw pointers are outside D22 shared-view materialization
//! drop-behavior: rejection precedes codegen; no owned value is synthesized

fn main:
    let value = 84
    let raw = &raw const value
    let snapshot: i32 = raw
