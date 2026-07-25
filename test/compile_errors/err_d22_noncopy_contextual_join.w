//! expect-error: `??` would need to copy a `Vec[i32]`, which is not Copy

fn main:
    let found: Vec[i32] = Vec.new()
    let fallback: Vec[i32] = Vec.new()
    let carrier: Option[&Vec[i32]] = Some(&found)
    let owned = carrier ?? fallback
