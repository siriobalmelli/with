//! D27-NON-COMPLIANT
//! owner-stage: E3
//! required-verdict: runs
//! exact-type: `values.get(0)` is `&Option[i32]`; unwrap must OBSERVE through the
//! view (transparent eliminator, D22 §10 extended to element views) yielding the
//! payload, which the typed binding materializes. TODAY the consuming-receiver
//! gate rejects it (honest error, not a miscompile); the interim spelling is
//! `remove(0).unwrap()`.
//! expected-diagnostic: none (today: consuming method requires an owned receiver)
//! drop-behavior: no element copy; the Option stays owned by the vec

fn main:
    var values: Vec[Option[i32]] = Vec.new()
    values.push(Some(5))
    let x: i32 = values.get(0).unwrap()
    assert(x == 5)
