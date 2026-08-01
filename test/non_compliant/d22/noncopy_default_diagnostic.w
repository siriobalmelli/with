//! D22-NON-COMPLIANT
//! owner-stage: 8
//! required-verdict: check-fail at the `??` join
//! exact-type: success is `&Vec[i64]`; default is owned `Vec[i64]`
//! expected-diagnostic: `??` would need to copy a non-Copy Vec; offer only applicable `.cloned()`, borrowed-default, or `remove` remedies
//! origin-set: no result is formed; success would have `{jobs}`
//! drop-behavior: rejection precedes codegen; both map and default retain ownership

use std.collections.HashMap
fn main:
    var jobs: HashMap[i32, Vec[i64]] = HashMap.new()
    let stored: Vec[i64] = Vec.new()
    stored.push(54)
    jobs.insert(1, move stored)

    // Must explain that ?? would need to copy a non-Copy Vec, then offer
    // .cloned(), a borrowed default, or remove only when each is applicable.
    let owned = jobs.get(1) ?? Vec.new()
    assert(owned.len() == 1)
