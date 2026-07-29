# D27 element-view acceptance matrix (NON-COMPLIANT lane)

Versioned per docs/d27-implementation-plan.md stage E0. Excluded from the
green runner, like ../d22. Each fixture header records the REQUIRED D27
verdict and its owner stage; promote a fixture to the active lanes only in
the stage that implements its requirement, and never weaken one to make a
stage green.

Baseline survey against v0.15.1-gc7dc28ce6 (2026-07-31):

| Cell | Today | Required | Owner |
|---|---|---|---|
| copy_index_unannotated_let | runs | runs (types flip to view internally) | E1 |
| copy_get_operator_demand | runs | runs | E1 |
| copy_typed_let_materializes | runs | runs | E1 |
| copy_call_arg_materializes | runs | runs | E1 |
| array_elem_operator_demand | runs | runs | E1 |
| drop_elem_index_let_observes | runs | runs (binds view, no copy) | E1 |
| drop_elem_get_let_observes | runs | runs (binds view, no copy) | E1 |
| drop_elem_explicit_borrow | runs | runs | E1 |
| mut_index_chain_in_place | runs | runs (place chain) | E1 |
| mut_index_direct_write | runs | runs | E1 |
| mut_get_chain_error | **runs (issue-64 aliasing accident)** | compile-error §15.2 | E1 |
| drop_elem_return_owned_error | **runs (#715 escape)** | compile-error §13.6 | E1 |
| drop_elem_typed_let_error | compile-error (interim gate) | compile-error (structural) | E3 |
| drop_elem_call_arg_error | compile-error (interim gate) | compile-error (structural) | E3 |
| drop_elem_assign_error | compile-error (interim gate) | compile-error (structural) | E3 |
| drop_elem_struct_field_error | compile-error (interim gate) | compile-error (structural) | E3 |
| drop_elem_let_then_consume_error | **runs (gate keys on expressions)** | compile-error §13.6 at consume | E3 |
| view_liveness_get_after_push_error | **runs (copy shape today)** | compile-error §3.2 | E3 |
| drop_elem_remove_transfers | runs | runs (drop exactly once via binding) | E2 |

Cells added during the E1+E2 stage2-miscompile fix (2026-08-01), from the two
compiler-scale defects the 19-cell baseline missed:

| Cell | Today | Required | Owner |
|---|---|---|---|
| copy_ptr_elem_cast_materializes | runs | runs (cast converts the pointee, not the slot address) | E1 |
| copy_elem_var_reassign_error | compile-error | compile-error (owned RHS into ref-typed binding) | E1 |
| copy_elem_var_typed_owned | runs | runs (typed var is an owned demand) | E1 |
| explicit_borrow_cast_address | runs | runs (`&place as *T` keeps address semantics) | E1 |

str elements are deliberately absent: owned strs are currently never freed
(#691); the str campaign owns those cells and should add them here when the
flip lands.
