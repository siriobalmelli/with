//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: runs
//! exact-type: `q` is `&*const i32`; the cast is an owned demand — it converts the
//! materialized pointee, never the slot address (the stage2 intern-arena miscompile)
//! expected-diagnostic: none
//! drop-behavior: no element copy dropped; pointers are Copy

fn main:
    let x = 5
    var v: Vec[*const i32] = Vec.new()
    let p = &raw const x
    v.push(p)
    let direct = p as i64
    let q = v.get(0)
    let through = q as i64
    assert(direct == through)
    let typed: *const i32 = v.get(0)
    assert(typed as i64 == direct)
