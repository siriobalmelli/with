//! D22-NON-COMPLIANT
//! owner-stage: 6
//! required-verdict: compile-and-run under `--debug-alloc`
//! exact-type: `Owner.map` is an owned `HashMap[i32, i32]`
//! expected-diagnostic: none
//! origin-set: no ephemeral view escapes
//! drop-behavior: aggregate construction transfers the map into `Owner`; the map header and tables drop exactly once
//! expect-debug-alloc: leak count=0

type Owner { map: HashMap[i32, i32] }

fn make_owner() -> Owner:
    let map: HashMap[i32, i32] = HashMap.new()
    Owner { map }

fn main:
    let owner = make_owner()
    assert(owner.map.len() == 0)
