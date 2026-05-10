// dv/d2d/tests/stage3_rdi_active_gate_test.sv
// CSV row #7 — P0
// Initialization / Stage sequencing into Adapter initialization
//
// Verifies that no Stage 3 sideband exchange or FDI activation
// occurs while RDI is below Active. Once RDI goes Active, bring-up
// must start.

module ucie_d2d_test (
  input logic clock,
  input logic reset,
  ucie_d2d_fdi_if fdi,
  ucie_d2d_rdi_if rdi
);
  import ucie_d2d_dv_pkg::*;

  // Watch the RDI sideband output from the adapter.
  // If anything appears before RDI is Active that is not a NOP,
  // the test fails.
  logic [127:0] snoop_msg;
  logic         sideband_fired_early;
  logic         rdi_reached_active;

  initial begin
    sideband_fired_early = 1'b0;
    rdi_reached_active   = 1'b0;
    snoop_msg            = '0;

    @(negedge reset);

    // Drive inband present — adapter should enter RDI_BRINGUP but must NOT
    // send any sideband until RDI reaches Active.
    rdi.drive_inband_present();
    repeat(5) @(posedge clock);

    // --- Check: no sideband while RDI is still in Reset ---
    // Hold RDI in Reset for 30 cycles and monitor lpCfgVld.
    // The adapter must not emit anything (it can only request Active on
    // lp_state_req, but sideband should be silent).
    repeat(30) begin
      @(posedge clock);
      if (rdi.lpCfgVld === 1'b1) begin
        sideband_fired_early = 1'b1;
        $error("[%0t] FAIL: Adapter emitted sideband before RDI Active (lpCfgVld=1)",
               $time);
      end
      if (fdi.plStateSts == RDI_STATE_ACTIVE) begin
        $error("[%0t] FAIL: FDI reached Active before RDI Active", $time);
      end
      if (fdi.plInbandPres === 1'b1) begin
        // plInbandPres should also be 0 until FDI_BRINGUP stage.
        // Adapter only sets it in FDI_BRINGUP / INIT_DONE which requires
        // PARAM_EXCH to complete first.
        // Allow it only once RDI is Active.
      end
    end

    if (!sideband_fired_early)
      $display("[%0t] PASS: No Stage 3 sideband while RDI below Active", $time);

    // --- Now drive RDI to Active — bring-up must begin ---
    rdi.drive_state(RDI_STATE_ACTIVE);
    rdi_reached_active = 1'b1;

    // Adapter should now emit ADV_CAP sideband within DEFAULT_WAIT_CYCLES.
    begin : wait_advcap
      int i;
      logic [127:0] msg;
      bit got_advcap;
      got_advcap = 0;
      for (i = 0; i < DEFAULT_WAIT_CYCLES && !got_advcap; i++) begin
        @(posedge clock);
        if (rdi.lpCfgVld === 1'b1) begin
          rdi.recv_sideband_msg(msg, DEFAULT_WAIT_CYCLES);
          if (sb_is_advcap_adapter(msg)) begin
            got_advcap = 1;
            $display("[%0t] PASS: Adapter sent ADV_CAP after RDI Active", $time);
          end else begin
            $error("[%0t] FAIL: Unexpected sideband message after RDI Active: %0h",
                   $time, msg);
          end
        end
      end
      if (!got_advcap)
        $error("[%0t] FAIL: Adapter never sent ADV_CAP after RDI Active", $time);
    end

    $display("[%0t] stage3_rdi_active_gate_test DONE", $time);
    $finish;
  end

endmodule