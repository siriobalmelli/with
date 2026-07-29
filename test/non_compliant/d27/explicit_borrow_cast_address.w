//! D27-NON-COMPLIANT
//! owner-stage: E1
//! required-verdict: runs
//! exact-type: `&place as *T` is the blessed address-taking spelling — an explicit
//! borrow operand keeps address semantics and never materializes its pointee
//! expected-diagnostic: none
//! drop-behavior: n/a

fn main:
    var arr: [3]i32 = [7, 8, 9]
    let p = &arr[0] as *const i32
    let first = unsafe *p
    assert(first == 7)
