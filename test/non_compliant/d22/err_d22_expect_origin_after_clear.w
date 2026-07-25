//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at `map.clear()`
//! exact-type: `view` is `&i32`
//! expected-diagnostic: cannot mutate `map` while `view` is a live view into it
//! origin-set: `expect` transfers `{map}` to `view`
//! drop-behavior: rejection precedes codegen; the map remains the sole owner

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 85)
    let view = map.get(1).expect("present")
    map.clear()
    assert(view == 85)
