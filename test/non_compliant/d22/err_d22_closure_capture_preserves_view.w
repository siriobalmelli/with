//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at the escaping closure capture
//! exact-type: `view` is `&i32`; `read` would return `&i32`
//! expected-diagnostic: escaping closure cannot capture ephemeral references
//! origin-set: the closure capture has `{map}`
//! drop-behavior: rejection precedes codegen; the map remains the sole owner

use std.collections.HashMap
fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 83)
    let view = map.get(1).unwrap()
    let read = () => view
    assert(read() == 83)
