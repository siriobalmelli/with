//! expect-check-fail: use of moved value

// #764: an enum constructor owns its payload; reusing the moved binding
// in a second constructor is a use-of-moved-value error, not a silent
// read of the blanked slot.
enum CtorReuseTok { Text(str) | End }
error CtorReuseErr =
    Bad(msg: str)
    Empty

fn main:
    let label = "x"
    let t = CtorReuseTok.Text(label)
    let e = CtorReuseErr.Bad(label)
    let _ = t
    let _ = e
