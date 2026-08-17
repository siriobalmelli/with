//! expect-check-fail: use of partially moved value

// #782: an assignment-RHS field read MOVES the str out of the owned
// local; using the local as a WHOLE value afterwards (here: a call
// argument) reads the blanked field and must be rejected.

type Capability { root: str, name: str }

fn takes_whole(c: &Capability) -> i64: c.root.len()

fn main:
    let cap = Capability { root: "/proj" ++ "", name: "ws" ++ "" }
    var picked = "" ++ ""
    picked = cap.root
    let n = takes_whole(cap)
    print_i64(n)
    print(picked)
