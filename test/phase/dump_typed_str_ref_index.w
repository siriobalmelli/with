//! args: --dump-typed
//! expect-check-stdout: bind byte: i32
//! expect-check-stdout-not: bind byte: <error>

fn first_byte(text: &str) -> i32:
    let byte = text[0]
    byte
