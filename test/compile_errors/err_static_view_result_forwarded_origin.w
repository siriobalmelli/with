//! expect-check-fail: returned view may outlive its origin 'values'

// The companion control for behav_static_view_result_used_locally: when the
// static method's result really is forwarded, its argument origin must remain
// visible to the enclosing return check.
type ForwardViewFactory { marker: i32 }

fn ForwardViewFactory.borrow(values: &Vec[i32]) -> &Vec[i32]: values

fn bad() -> &Vec[i32]:
    let values: Vec[i32] = Vec.new()
    ForwardViewFactory.borrow(&values)
