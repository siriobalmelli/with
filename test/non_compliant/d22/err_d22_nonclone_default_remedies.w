//! D22-NON-COMPLIANT
//! owner-stage: 8
//! required-verdict: check-fail at the `??` join
//! exact-type: success is `&Ticket`; default is owned `Ticket`
//! expected-diagnostic: `??` would need to copy a `Ticket`, which is not Copy; do not suggest `.cloned()`
//! origin-set: no result is formed; success would have `{tickets}`
//! drop-behavior: rejection precedes codegen; `tickets` retains ownership

type Ticket { number: i64 }

fn main:
    var tickets: HashMap[i32, Ticket] = HashMap.new()
    tickets.insert(1, Ticket { number: 67 })
    let owned = tickets.get(1) ?? Ticket { number: 68 }
    assert(owned.number == 67)
