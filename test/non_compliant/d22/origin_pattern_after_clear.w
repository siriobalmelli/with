//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at `map.clear()`
//! exact-type: structural `Some(view)` projection binds `view: &i32`
//! expected-diagnostic: cannot mutate `map` while `view` is a live view into it
//! origin-set: pattern projection preserves `{map}`
//! drop-behavior: rejection precedes codegen; the map remains the sole owner

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 42)
    let carrier: Option[&i32] = Some(map.get(1).unwrap())
    let Some(view) = carrier else return
    map.clear()
    assert(view == 42)
