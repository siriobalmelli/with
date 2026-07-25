//! D22-NON-COMPLIANT
//! owner-stage: 4
//! required-verdict: check-fail at `map.clear()`
//! exact-type: inferred `find` return and `view` are `&i32`
//! expected-diagnostic: cannot mutate `map` while `view` is a live view into it
//! origin-set: the inferred return forwards `{map}`
//! drop-behavior: rejection precedes codegen; the map remains the sole owner

fn find(map: &HashMap[i32, i32]): map.get(1).unwrap()

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 82)
    let view = find(&map)
    map.clear()
    assert(view == 82)
