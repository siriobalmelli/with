//! expect-run-output: "3\n2\n1\n"

use std.builtins.write
fn main:
    defer: write("1\n")
    defer:
        write("2\n")
    defer {
        write("3\n")
    }
