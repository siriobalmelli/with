//! expect-stdout: ok

use compiler.ClangBridge.*

fn test_unix_path_boundaries:
    assert(with_cimport_path_under_dir_for_test("/sdk/include/header.h", "/sdk/include", false))
    assert(not with_cimport_path_under_dir_for_test("/sdk/include-next/header.h", "/sdk/include", false))
    assert(with_cimport_path_under_dir_for_test("/sdk/include:1:1", "/sdk/include", false))

fn test_path_list_empty_entries:
    assert(with_cimport_isystem_entry_count_for_test("", false) == 0)
    assert(with_cimport_isystem_entry_count_for_test(":/one::/two:", false) == 2)
    assert(with_cimport_isystem_entry_count_for_test(";C:\\one;;D:/two;", true) == 2)

fn test_windows_path_normalization:
    assert(with_cimport_path_under_dir_for_test("c:/SDK/Include/header.h", "C:\\sdk\\include", true))
    assert(with_cimport_path_under_dir_for_test("C:\\Windows\\System32\\x.h", "c:/", true))
    assert(not with_cimport_path_under_dir_for_test("C:\\SDK\\Includes\\x.h", "c:/sdk/include", true))

fn test_temp_root_selection_and_synthetic_paths:
    assert(with_cimport_temp_root_for_test("/with/", "/tmp", "/temp", "/fallback", false) == "/with")
    assert(with_cimport_temp_root_for_test("", "/tmp/", "/temp", "/fallback", false) == "/tmp")
    assert(with_cimport_temp_root_for_test("", "", "C:\\Temp\\", "", true) == "C:\\Temp")
    assert(with_cimport_temp_root_for_test("", "", "", "", true) == "C:\\Windows\\Temp")
    assert(with_cimport_synthetic_path_for_test("c:\\temp\\with_cimport_abc", "C:\\Temp\\", true))
    assert(with_cimport_synthetic_path_for_test("/with/with_cimport_abc", "/with/", false))
    assert(not with_cimport_synthetic_path_for_test("/private/tmp/with_cimport_abc", "/tmp", false))
    assert(not with_cimport_temp_template_fits_for_test("/long-root", "with_cimport_XXXXXX", 8, false))

fn test_unsupported_macro_collection_is_soft:
    let session = with_cimport_parse_macros("#define CIM_UNSUPPORTED(fmt, ...) printf(fmt, __VA_ARGS__)\n")
    assert(session != 0)
    assert(with_cimport_isystem_error().len() == 0)
    with_cimport_dispose_macros(session)

fn main:
    test_unix_path_boundaries()
    test_path_list_empty_entries()
    test_windows_path_normalization()
    test_temp_root_selection_and_synthetic_paths()
    test_unsupported_macro_collection_is_soft()
    print("ok")
