// D27 respell (#740): mutation goes through the `[i]` element place;
// `get` observes — the binding holds a view and reads stay legal.

type Inner {
    tags: Vec[i32],
}

fn main:
    var inners: Vec[Inner] = Vec.new()
    inners.push(Inner { tags: Vec.new() })
    inners[0].tags.push(99)
    let item = inners.get(0)
    assert(item.tags.len() == 1)
    assert(inners.get(0).tags.get(0) == 99)
