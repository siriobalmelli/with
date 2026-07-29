fn main:
    var xs = Vec.new()
    xs.push(1)

    let last = xs.len() - 1
    let copied: i32 = xs.get(last)

    xs.pop()
    xs.push(2)

    assert(copied == 1)
