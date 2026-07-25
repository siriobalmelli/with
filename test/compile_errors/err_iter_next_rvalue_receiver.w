//! expect-check-fail: place receiver

// §15.3: next() mutates the iterator, so it needs a place receiver — the
// temporary returned by items.iter() in a direct chain is not one. Bind the
// iterator (`var iter = items.iter()`) to advance it.

type Inner {
    tags: Vec[i32],
}

fn main:
    var items: Vec[Inner] = Vec.new()
    items.push(Inner { tags: Vec.new() })
    items.iter().next().unwrap().tags.push(3)
