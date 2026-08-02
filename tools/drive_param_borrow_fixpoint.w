// #747: drive the param-borrow migration to a fixpoint. Each round:
//   git checkout <files>  (restores flip-hunk-free sources? NO — see below)
//   re-apply is handled by the caller keeping Sema.w's flip hunks OUT of
//   the file list; this driver only touches the listed files.
//   migrate --apply, flipped-stage1 check, attribute body errors to their
//   enclosing fn, grow the denylist, repeat until the error count stops
//   improving. Remaining errors are the hand-fix residue.
//
//   with run tools/drive_param_borrow_fixpoint.w <stage1> <listfile> <denylist> <scratch>
use std.process

extern fn with_fs_read_file(path: str) -> str
extern fn with_fs_write_file(path: str, data: str) -> i32
extern fn with_str_clone(s: str) -> str

fn sh(cmd: str) -> i32:
    let argv: Vec[str] = Vec.new()
    argv.push("/bin/sh")
    argv.push("-c")
    argv.push(cmd)
    run(&argv)

// Enclosing fn name for a body error: last `fn NAME` header at or above
// `line` in `path` (dotted names kept; impl methods resolve to the bare
// method name, which matches the migrator's keying for top-level fns and
// is conservative for methods).
fn enclosing_fn(path: str, line_no: i32) -> str:
    let text = with_fs_read_file(path)
    var current = ""
    var ln = 0
    for line in text.split("\n"):
        ln = ln + 1
        if ln > line_no: break
        var t = line
        while t.len() > 0 and (t.byte_at(0) == 32 or t.byte_at(0) == 9):
            t = t.slice(1, t.len())
        var name_part = ""
        if t.starts_with("fn "): name_part = t.slice(3, t.len())
        else if t.starts_with("mut fn "): name_part = t.slice(7, t.len())
        else if t.starts_with("pub fn "): name_part = t.slice(7, t.len())
        else if t.starts_with("move fn "): name_part = t.slice(8, t.len())
        if name_part.len() > 0:
            var e = 0 as i64
            while e < name_part.len():
                let c = name_part.byte_at(e)
                let ident = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95 or c == 46
                if not ident: break
                e = e + 1
            if e > 0: current = with_str_clone(name_part.slice(0, e))
    current

fn main -> i32:
    let argv = args()
    if argv.len() < 5:
        eprint("usage: drive_param_borrow_fixpoint <stage1> <listfile> <denylist> <scratch>")
        return 2
    let stage1 = argv.get(1)
    let listfile = argv.get(2)
    let denylist = argv.get(3)
    let scratch = argv.get(4)
    let files_blob = with_fs_read_file(listfile)
    var files_sh = ""
    for f in files_blob.split("\n"):
        if f.len() > 0: files_sh = files_sh ++ " " ++ f
    var round = 0
    var last_errs = 2147483647
    while round < 12:
        round = round + 1
        let _r = sh("git checkout --" ++ files_sh)
        let _m = sh("with run tools/migrate_param_borrows.w --apply " ++ denylist ++ " " ++ files_sh ++ " > " ++ scratch ++ "/mig_round.log 2>&1")
        let _c = sh(stage1 ++ " check src/main.w 2> " ++ scratch ++ "/round.txt")
        let diags = with_fs_read_file(scratch ++ "/round.txt")
        var errs = 0
        var new_denies = 0
        var pending_err = false
        for line in diags.split("\n"):
            if line.starts_with("error:"):
                errs = errs + 1
                pending_err = true
                continue
            if pending_err and line.contains("--> "):
                pending_err = false
                let loc = line.split("--> ").get(1)
                let parts = loc.split(":")
                if parts.len() >= 2:
                    let epath = parts.get(0)
                    var eline = 0
                    for ch_i in 0..parts.get(1).len():
                        let c = parts.get(1).byte_at(ch_i)
                        if c >= 48 and c <= 57: eline = eline * 10 + (c as i32 - 48)
                    let fname = enclosing_fn(epath, eline)
                    if fname.len() > 0:
                        // Deny every borrowed param of the implicated fn this
                        // round (conservative; over-denial only costs clones).
                        let miglog = with_fs_read_file(scratch ++ "/mig_round.log")
                        for ml in miglog.split("\n"):
                            let marker = ": " ++ fname ++ "("
                            if ml.contains(marker):
                                let pstart = ml.split("(").get(1)
                                let pname = pstart.split(")").get(0)
                                let entry = fname ++ "\t" ++ pname
                                let existing = with_fs_read_file(denylist)
                                if not ("\n" ++ existing).contains("\n" ++ entry ++ "\n"):
                                    let _w = with_fs_write_file(denylist, existing ++ entry ++ "\n")
                                    new_denies = new_denies + 1
        print(f"round {round}: errors={errs} new-denies={new_denies}")
        if errs == 0: break
        if new_denies == 0 and errs >= last_errs:
            print("fixpoint reached with residue; see round.txt")
            break
        last_errs = errs
    0
