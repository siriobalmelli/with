//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at `map.clear()`
//! exact-type: built-in `?` exposes `view: &i32`
//! expected-diagnostic: cannot mutate `map` while `view` is a live view into it
//! origin-set: `?` preserves `{map}`
//! drop-behavior: rejection precedes codegen; the map remains the sole owner

use std.collections.HashMap
fn observe_after_mutation() -> Option[i32]:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 43)
    let view = map.get(1)?
    map.clear()
    Some(view)

fn main:
    let _ = observe_after_mutation()
