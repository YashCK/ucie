// d2d_bringup_tasks.svh
// Shared helper tasks included by all test files.
// Performs the full Stage 3 bring-up sequence:
//   RDI inband_pres -> RDI Active -> AdvCap exchange ->
//   FDI request_active -> REQ/RSP_ACTIVE exchange -> FDI Active

// Complete raw-mode bring-up. After this task returns,
// fdi.plStateSts == RDI_STATE_ACTIVE and the link is ready for data.
task automatic run_raw_bringup(
  virtual ucie_d2d_fdi_if fdi,
  virtual ucie_d2d_rdi_if rdi,
  input  logic             clock
);
  import ucie_d2d_dv_pkg::*;
  logic [127:0] sb_msg;

  // --- Stage 2 complete: PHY signals inband presence ---
  rdi.drive_inband_present();
  repeat(5) @(posedge clock);

  // --- RDI goes to Active (PHY training done) ---
  rdi.drive_state(RDI_STATE_ACTIVE);
  repeat(3) @(posedge clock);

  // --- Stage 3 Part 1: AdapterSM sends ADV_CAP on RDI sideband ---
  // Wait for adapter to emit ADV_CAP then send the remote AdvCap back.
  rdi.recv_sideband_msg(sb_msg, 200);
  assert(sb_is_advcap_adapter(sb_msg))
    else $fatal(1, "Expected ADV_CAP from adapter, got %0h", sb_msg);

  // Send remote AdvCap (raw+streaming Stack0) so adapter moves to FDI_BRINGUP
  rdi.send_sideband_msg(sb_advcap_adapter());
  repeat(3) @(posedge clock);

  // --- Stage 3 Part 2: FDI bring-up ---
  // Adapter now drives plInbandPres=1 on FDI. Protocol Layer requests Active.
  fdi.request_active();
  repeat(3) @(posedge clock);

  // Adapter sends REQ_ACTIVE on RDI sideband; we play the remote PHY role.
  rdi.recv_sideband_msg(sb_msg, 200);
  // Could be RSP_ACTIVE or REQ_ACTIVE depending on which side initiates first.
  // Send both REQ_ACTIVE and RSP_ACTIVE to complete the four-way handshake.
  rdi.send_sideband_msg(sb_adapter0_req_active());
  repeat(2) @(posedge clock);
  rdi.send_sideband_msg(sb_adapter0_rsp_active());
  repeat(3) @(posedge clock);

  // Acknowledge rx_active on FDI so adapter can assert plRxActiveReq
  fdi.lpRxActiveSts = 1'b1;
  repeat(3) @(posedge clock);

  // Wait for FDI to reach Active (up to 100 cycles)
  begin : wait_fdi_active
    int i;
    for (i = 0; i < 100; i++) begin
      if (fdi.plStateSts == RDI_STATE_ACTIVE) break;
      @(posedge clock);
    end
    if (fdi.plStateSts != RDI_STATE_ACTIVE)
      $fatal(1, "run_raw_bringup: FDI never reached Active (plStateSts=%0h)",
             fdi.plStateSts);
  end

  $display("[%0t] run_raw_bringup: link is Active", $time);
endtask
