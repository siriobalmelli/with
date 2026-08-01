//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at `map.clear()`
//! exact-type: structural `Ok(value)` projection binds `view: &i32`
//! expected-diagnostic: cannot mutate `map` while `view` is a live view into it
//! origin-set: Result construction and pattern projection preserve `{map}`
//! drop-behavior: rejection precedes codegen; the map remains the sole owner

use std.collections.HashMap
fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 127)
    let carrier: Result[&i32, str] = Ok(map.get(1).unwrap())
    let view = match carrier:
        Ok(value) => value
        Err(_) => return
    map.clear()
    assert(view == 127)
