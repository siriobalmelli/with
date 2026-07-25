//! D22-NON-COMPLIANT
//! owner-stage: 8
//! required-verdict: check-fail at the `??` join
//! exact-type: success is `&Vec[i64]`; the named default is owned `Vec[i64]`
//! expected-diagnostic: `??` would need to copy a `Vec[i64]`, which is not Copy; suggest a lifetime-correct borrowed default
//! origin-set: no result is formed; success would have `{jobs}`
//! drop-behavior: rejection precedes codegen; `jobs` and `fallback` retain ownership

fn main:
    var jobs: HashMap[i32, Vec[i64]] = HashMap.new()
    let stored: Vec[i64] = Vec.new()
    jobs.insert(1, move stored)
    let fallback: Vec[i64] = Vec.new()
    let owned = jobs.get(1) ?? fallback
    assert(owned.len() == 0)
