//! expect-check-fail: use of moved value

// #782 arm 2: `let (a, b) = t` consumes the tuple (MIR moves every
// element), so a later projection reads blanked storage and must be
// rejected.

fn pair() -> (i32, str): (42, "x" ++ "")

fn main:
    let t = pair()
    let (a, b) = t
    print(t.1)
    let _ = a
    print(b)
