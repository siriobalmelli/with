//! expect-stdout: ok

// D30 R2a pin: runtime sources embed like the stdlib and resolve under the
// <embedded-rt>/ prefix. A missing or truncated embedding must fail here,
// not at R2b's in-unit parse.
use compiler.EmbeddedRuntime

fn main:
    let core = embedded_rt_source("rt/rt_core.w")
    assert(core.len() > 10000, "rt_core.w embeds non-trivially")
    assert(core.contains("pub fn with_str_eq_ref"), "embedded rt_core is current")

    let listing = embedded_rt_list_modules()
    assert(listing.contains("rt/rt_core.w"))
    assert(listing.contains("rt/panic_runtime.w"))
    assert(listing.contains("rt/darwin_aarch64.w"))
    assert(listing.contains("rt/windows_x86_64.w"))

    assert(embedded_rt_resolve_path("rt/rt_core.w") == "<embedded-rt>/rt/rt_core.w")
    assert(embedded_rt_resolve_path("rt/nope.w").len() == 0, "unknown module does not resolve")
    assert(embedded_rt_resolve_path("std/io.w").len() == 0, "std namespace is not rt")
    assert(embedded_rt_rel_path("<embedded-rt>/rt/panic_runtime.w") == "rt/panic_runtime.w")
    assert(embedded_rt_rel_path("rt/panic_runtime.w").len() == 0, "unprefixed path is not embedded")
    print("ok")
