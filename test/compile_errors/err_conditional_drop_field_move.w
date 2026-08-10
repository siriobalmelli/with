//! expect-check-fail: field move inside drop cannot be conditional

type ConditionalDropFieldFile { id: str }
impl Drop for ConditionalDropFieldFile:
    fn drop(move self: Self):
        let _ = self.id

fn eat_conditional_drop_field_file(f: ConditionalDropFieldFile): ()

type ConditionalDropFieldWrapper { fd: ConditionalDropFieldFile, enabled: bool }
impl Drop for ConditionalDropFieldWrapper:
    fn drop(move self: Self):
        // A consuming USE under a conditional (a plain `let` merely observes
        // the field — D22/D27 — and stays legal in either position).
        if self.enabled:
            eat_conditional_drop_field_file(self.fd)
