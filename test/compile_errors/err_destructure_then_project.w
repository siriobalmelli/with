//! expect-check-fail: use of moved value

// #782 arm 2: `let (a, b) = t` consumes the tuple (MIR moves every
// element), so a later projection reads blanked storage and must be
// rejected.

fn pair() -> (i32, str): (42, "x" ++ "")

fn main:
    let t = pair()
    let (a, b) = t
    print_i64(t.1.len())
    print_i64(a as i64)
    print(b)
