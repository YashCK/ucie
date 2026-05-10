// dv/d2d/tests/linkerror_exit_blocked_test.sv
// CSV row #21 — P1
// State Machines / LinkError exit blocked until Adapter side has entered LinkError
//
// From AdapterSM:
//   is(RDIState.linkError) {
//     when((fdi_lp_state_req === active || rdi_pl_state_sts === linkError) && rxDeactive)
//       -> reset
//   }
// So the adapter must NOT exit LinkError on RDI until:
//   a) FDI plStateSts has reached LinkError (adapter side), AND
//   b) rxDeactive is true.
//
// This test drives RDI LinkError, then immediately drives
// lp_state_req=Active recovery stimulus before rxDeactive can happen,
// and verifies the adapter stays in LinkError.

module ucie_d2d_test (
  input logic clock,
  input logic reset,
  ucie_d2d_fdi_if fdi,
  ucie_d2d_rdi_if rdi
);
  import ucie_d2d_dv_pkg::*;
  `include "d2d_bringup_tasks.svh"

  initial begin
    @(negedge reset);
    run_raw_bringup(fdi, rdi, clock);

    // --- Force LinkError ---
    $display("[%0t] Injecting RDI LinkError", $time);
    rdi.drive_state(RDI_STATE_LINKERROR);

    // Wait 1 cycle — FDI is propagating to LinkError.
    @(posedge clock);

    // --- Attempt premature recovery ---
    // Drive lp_state_req = Active immediately (before rxDeactive).
    // The adapter should ignore this until FDI has truly entered LinkError
    // and rxDeactive is satisfied.
    fdi.lpStateReq = RDI_STATE_REQ_ACTIVE;

    // Keep lpRxActiveSts=1 for a few cycles so rxDeactive stays false.
    // rxDeactive = !lpRxActiveSts && !fdiPlRxActiveReqReg
    fdi.lpRxActiveSts = 1'b1;

    repeat(5) @(posedge clock);

    // Adapter should still be in LinkError (not Reset)
    assert(fdi.plStateSts == RDI_STATE_LINKERROR)
      else $error("[%0t] FAIL: Adapter exited LinkError before rxDeactive (state=%0h)",
                  $time, fdi.plStateSts);
    $display("[%0t] PASS: Adapter stayed in LinkError during premature recovery attempt",
             $time);

    // --- Now properly complete the exit sequence ---
    // De-assert lpRxActiveSts so rxDeactive becomes true.
    fdi.lpRxActiveSts = 1'b0;
    // rdi_pl_state_sts is already LinkError (from above).
    // Per AdapterSM: (fdi_lp_state_req == active || rdi_pl_state_sts == linkError)
    // && rxDeactive -> reset. Since rdi_pl_state_sts == linkError, this triggers.
    repeat(5) @(posedge clock);

    // Now adapter should exit to Reset
    assert(fdi.plStateSts == RDI_STATE_RESET)
      else $error("[%0t] FAIL: Adapter did not return to Reset after proper exit (state=%0h)",
                  $time, fdi.plStateSts);
    $display("[%0t] PASS: Adapter correctly exited LinkError to Reset after rxDeactive",
             $time);

    fdi.lpStateReq = RDI_STATE_REQ_NOP;

    $display("[%0t] linkerror_exit_blocked_test DONE", $time);
    $finish;
  end

endmodule