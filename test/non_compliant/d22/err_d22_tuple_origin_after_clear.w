//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at `map.clear()`
//! exact-type: `carrier` is `(&i32, bool)`; projected `view` is `&i32`
//! expected-diagnostic: cannot mutate `map` while `view` is a live view into it
//! origin-set: tuple construction and projection preserve `{map}`
//! drop-behavior: rejection precedes codegen; the map remains the sole owner

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 75)
    let carrier = (map.get(1).unwrap(), true)
    let (view, _) = carrier
    map.clear()
    assert(view == 75)
