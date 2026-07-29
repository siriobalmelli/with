//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: compile-error
//! exact-type: `off` binds the `&i32` view; the reassignment's RHS materializes an
//! owned i32, which cannot be stored into a reference-typed binding (no borrow is
//! created; lowering would store value bits into a pointer-typed local — the D22-era
//! seed segfaults on the map-view spelling of this shape)
//! expected-diagnostic: cannot assign an owned value to a reference-typed binding
//! drop-behavior: rejection precedes codegen

fn main:
    var xs: Vec[i32] = Vec.new()
    xs.push(50)
    var off = xs.get(0)
    off = off + 1
    assert(off == 51)
