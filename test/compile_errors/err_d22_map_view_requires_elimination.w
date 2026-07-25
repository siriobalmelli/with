//! expect-check-fail: comparison operands must have compatible types

fn main:
    var values: HashMap[i32, i32] = HashMap.new()
    values.insert(1, 1)
    assert(values.get(1) == 1)
