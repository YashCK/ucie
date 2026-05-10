// dv/d2d/tests/fdi_bringup_after_param_test.sv
// CSV row #8 — P0
// Initialization / FDI bring-up after successful parameter exchange
//
// Verifies:
// 1. FDI plStateSts never reaches Active before parameter exchange completes.
// 2. No data flows on FDI plValid before FDI Active.
// 3. After exchange completes the link reaches Active and the first
//    legal data beat is accepted.

module ucie_d2d_test (
  input logic clock,
  input logic reset,
  ucie_d2d_fdi_if fdi,
  ucie_d2d_rdi_if rdi
);
  import ucie_d2d_dv_pkg::*;
  `include "d2d_bringup_tasks.svh"

  logic [127:0] sb_msg;

  // ---- Background checker: no early FDI data ----
  initial begin
    forever begin
      @(posedge clock);
      if (!reset && fdi.plStateSts != RDI_STATE_ACTIVE && fdi.plValid === 1'b1)
        $error("[%0t] FAIL: FDI plValid asserted before FDI Active", $time);
    end
  end

  initial begin
    @(negedge reset);

    // ----- Step-by-step bring-up so we can check at each gate -----

    // Stage 2: inband presence
    rdi.drive_inband_present();
    repeat(5) @(posedge clock);

    // Confirm FDI still in Reset
    assert(fdi.plStateSts == RDI_STATE_RESET)
      else $error("[%0t] FAIL: FDI left Reset before RDI Active (state=%0h)",
                  $time, fdi.plStateSts);

    // RDI goes Active
    rdi.drive_state(RDI_STATE_ACTIVE);
    repeat(3) @(posedge clock);

    // FDI must still be Reset (param exchange not done yet)
    assert(fdi.plStateSts == RDI_STATE_RESET)
      else $error("[%0t] FAIL: FDI left Reset before AdvCap exchanged (state=%0h)",
                  $time, fdi.plStateSts);
    $display("[%0t] PASS: FDI in Reset after RDI Active, before AdvCap", $time);

    // Consume adapter's ADV_CAP
    rdi.recv_sideband_msg(sb_msg, DEFAULT_WAIT_CYCLES);
    assert(sb_is_advcap_adapter(sb_msg))
      else $fatal(1, "Expected ADV_CAP, got %0h", sb_msg);

    // FDI must still be Reset (remote AdvCap not yet sent)
    assert(fdi.plStateSts == RDI_STATE_RESET)
      else $error("[%0t] FAIL: FDI left Reset before remote AdvCap (state=%0h)",
                  $time, fdi.plStateSts);
    $display("[%0t] PASS: FDI in Reset after local AdvCap TX, before remote AdvCap",
             $time);

    // Send remote AdvCap — param exchange completes
    rdi.send_sideband_msg(sb_advcap_adapter());
    repeat(5) @(posedge clock);

    // Adapter now in FDI_BRINGUP; plInbandPres should be 1
    assert(fdi.plInbandPres === 1'b1)
      else $error("[%0t] FAIL: plInbandPres not set after AdvCap exchange", $time);
    $display("[%0t] PASS: plInbandPres=1 after AdvCap exchange", $time);

    // FDI STILL must not be Active yet (REQ/RSP_ACTIVE handshake pending)
    assert(fdi.plStateSts != RDI_STATE_ACTIVE)
      else $error("[%0t] FAIL: FDI Active before REQ/RSP_ACTIVE handshake", $time);

    // Protocol Layer requests Active
    fdi.request_active();
    repeat(3) @(posedge clock);

    // Complete REQ/RSP_ACTIVE sideband handshake
    rdi.recv_sideband_msg(sb_msg, DEFAULT_WAIT_CYCLES);
    rdi.send_sideband_msg(sb_adapter0_req_active());
    repeat(2) @(posedge clock);
    rdi.send_sideband_msg(sb_adapter0_rsp_active());
    repeat(3) @(posedge clock);

    // rx_active handshake
    fdi.lpRxActiveSts = 1'b1;
    repeat(5) @(posedge clock);

    // Now FDI must reach Active
    begin : wait_active
      int i;
      for (i = 0; i < 50; i++) begin
        if (fdi.plStateSts == RDI_STATE_ACTIVE) break;
        @(posedge clock);
      end
      assert(fdi.plStateSts == RDI_STATE_ACTIVE)
        else $fatal(1, "[%0t] FAIL: FDI never reached Active", $time);
    end
    $display("[%0t] PASS: FDI reached Active after full parameter exchange", $time);

    // ---- First legal data beat ----
    // Drive one data beat from FDI (Protocol Layer side)
    @(posedge clock);
    fdi.lpValid = 1'b1;
    fdi.lpIrdy  = 1'b1;
    fdi.lpData  = 256'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0_FEED_FACE_DEAD_BEEF_CAFE_BABE_1234_5678;

    // Wait for plTrdy from adapter
    begin : wait_trdy
      int i;
      for (i = 0; i < 20; i++) begin
        @(posedge clock);
        if (fdi.plTrdy === 1'b1) break;
      end
      assert(fdi.plTrdy === 1'b1)
        else $error("[%0t] FAIL: plTrdy never asserted for first data beat", $time);
    end
    @(posedge clock);
    fdi.lpValid = 1'b0;
    fdi.lpIrdy  = 1'b0;

    // Data beat should appear on RDI
    begin : wait_rdi_data
      int i;
      for (i = 0; i < 20; i++) begin
        @(posedge clock);
        if (rdi.lpValid === 1'b1) break;
      end
      assert(rdi.lpValid === 1'b1)
        else $error("[%0t] FAIL: RDI lpValid never asserted for first data beat",
                    $time);
    end
    $display("[%0t] PASS: First data beat accepted and forwarded to RDI", $time);

    $display("[%0t] fdi_bringup_after_param_test DONE", $time);
    $finish;
  end

endmodule