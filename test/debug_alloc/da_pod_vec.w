//! expect-debug-alloc: leak count=0
use std.builtins.print_i32
fn main:
    let ns: Vec[i32] = Vec.new()
    ns.push(1)
    ns.push(2)
    print_i32(ns.len() as i32)
