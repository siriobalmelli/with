//! expect-stdout: ok

use std.process

fn main:
    let true_bin = env("WITH_TRUE")
    let true_path = if true_bin.len() > 0: true_bin else: "/usr/bin/true"
    assert(command(true_path).run() == 0)

    let test_bin = env("WITH_TEST")
    let test_path = if test_bin.len() > 0: test_bin else: "/bin/test"
    let eq = command(test_path).arg("with").arg("=").arg("with")
    assert(eq.status() == 0)

    let ne = command(test_path).arg("with").arg("=").arg("shell")
    assert(ne.status() != 0)

    print("ok")
