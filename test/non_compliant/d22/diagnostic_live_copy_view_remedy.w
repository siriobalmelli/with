//! D22-NON-COMPLIANT
//! owner-stage: 8
//! required-verdict: check-fail at `counts.clear()` with the complete D22 Section 11.1 diagnostic
//! exact-type: unannotated `count` is `&i32`, not `i32`
//! expected-diagnostic: name `counts`, `count`, mutation, and later use; offer machine-applicable `let count: i32 = ...`
//! origin-set: `count` has `{counts}`
//! drop-behavior: rejection precedes codegen; `counts` remains the sole owner

fn main:
    var counts: HashMap[str, i32] = HashMap.new()
    counts.insert("api", 119)
    let count = counts.get("api").unwrap()
    counts.clear()
    assert(count == 119)
