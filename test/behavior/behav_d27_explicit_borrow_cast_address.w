//! expect-exit: 0

// D27 E1: `&place as *T` keeps address semantics and never materializes the
// pointee before the cast.

fn main:
    var arr: [3]i32 = [7, 8, 9]
    let p = &arr[0] as *const i32
    let first = unsafe *p
    assert(first == 7)
