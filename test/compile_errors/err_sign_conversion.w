//! expect-error: narrowing or sign

use std.builtins.print_i32
fn main:
    let x: i32 = 42
    let y: u32 = x
    print_i32(y as i32)
