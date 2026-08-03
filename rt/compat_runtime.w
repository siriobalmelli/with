// rt/compat_runtime.w -- portable compiler-only runtime surface.
//
// Keep the public with_* ABI here. Platform-specific process, environment,
// signal, and stack-limit behavior lives in the platform runtime backend.

extern fn rt_compat_setenv_str(name: str, value: str) -> i32
extern fn rt_compat_install_interrupt_handlers() -> Unit
extern fn rt_compat_raise_stack_limit() -> Unit
extern fn rt_compat_interrupt_requested() -> i32
extern fn rt_compat_exec_binary(path: str) -> i32
extern fn rt_compat_exec_argv(args: str) -> i32
extern fn rt_compat_exec_argv_cwd(args: str, cwd: str) -> i32
extern fn rt_compat_exec_argv_capture(args: str, stdout_path: str, stderr_path: str, timeout_ms: i32) -> i32
extern fn rt_compat_exec_argv_capture_input(args: str, stdout_path: str, stderr_path: str, timeout_ms: i32, stdin_path: str) -> i32
extern fn rt_compat_exec_argv_capture_cwd(args: str, stdout_path: str, stderr_path: str, timeout_ms: i32, cwd: str) -> i32
extern fn rt_compat_exec_argv_capture_spawn(args: str, stdout_path: str, stderr_path: str) -> i32
extern fn rt_compat_exec_wait(pid: i32, timeout_ms: i32) -> i32

// #747 ref shim: rebuild a view str from a BORROWED str so the flipped
// public with_* surface can forward to the consuming rt_compat_* backend.
// BOOTSTRAP INTERIM spelling — see rt/rt_core.w str_ref_view.
type CompatRawStr:
    ptr: *const u8
    len: i64

fn str_ref_view(s: &str) -> str:
    let data = unsafe **(&s as *const *const *const u8)
    let raw = CompatRawStr { ptr: data, len: s.len() }
    let p = &raw as *const str
    unsafe *p

pub fn with_setenv_str(name: &str, value: &str) -> i32:
    rt_compat_setenv_str(str_ref_view(name), str_ref_view(value))

pub fn with_install_interrupt_handlers() -> Unit:
    rt_compat_install_interrupt_handlers()

pub fn with_raise_stack_limit() -> Unit:
    rt_compat_raise_stack_limit()

pub fn with_interrupt_requested() -> i32:
    rt_compat_interrupt_requested()

pub fn with_exec_binary(path: &str) -> i32:
    rt_compat_exec_binary(str_ref_view(path))

pub fn with_exec_argv(args: &str) -> i32:
    rt_compat_exec_argv(str_ref_view(args))

pub fn with_exec_argv_cwd(args: &str, cwd: &str) -> i32:
    rt_compat_exec_argv_cwd(str_ref_view(args), str_ref_view(cwd))

pub fn with_exec_argv_capture(args: &str, stdout_path: &str, stderr_path: &str, timeout_ms: i32) -> i32:
    rt_compat_exec_argv_capture(str_ref_view(args), str_ref_view(stdout_path), str_ref_view(stderr_path), timeout_ms)

pub fn with_exec_argv_capture_input(args: &str, stdout_path: &str, stderr_path: &str, timeout_ms: i32, stdin_path: &str) -> i32:
    rt_compat_exec_argv_capture_input(str_ref_view(args), str_ref_view(stdout_path), str_ref_view(stderr_path), timeout_ms, str_ref_view(stdin_path))

pub fn with_exec_argv_capture_cwd(args: &str, stdout_path: &str, stderr_path: &str, timeout_ms: i32, cwd: &str) -> i32:
    rt_compat_exec_argv_capture_cwd(str_ref_view(args), str_ref_view(stdout_path), str_ref_view(stderr_path), timeout_ms, str_ref_view(cwd))

pub fn with_exec_argv_capture_spawn(args: &str, stdout_path: &str, stderr_path: &str) -> i32:
    rt_compat_exec_argv_capture_spawn(str_ref_view(args), str_ref_view(stdout_path), str_ref_view(stderr_path))

pub fn with_exec_wait(pid: i32, timeout_ms: i32) -> i32:
    rt_compat_exec_wait(pid, timeout_ms)
