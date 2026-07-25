//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at `fallback.clear()`
//! exact-type: the all-reference `if` result `view` is `&i32`
//! expected-diagnostic: cannot mutate `fallback` while `view` is a live view into it
//! origin-set: the `if` join gives `view` `{primary, fallback}`
//! drop-behavior: rejection precedes codegen; both maps retain ownership

fn main:
    var primary: HashMap[i32, i32] = HashMap.new()
    var fallback: HashMap[i32, i32] = HashMap.new()
    primary.insert(1, 105)
    fallback.insert(1, 106)
    let view = if true: primary.get(1).unwrap() else: fallback.get(1).unwrap()
    fallback.clear()
    assert(view == 105)
