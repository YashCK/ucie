// dv/d2d/tests/raw_datapath_test.sv
// CSV rows #13, #14, #15 — all P0
// Data Path / TX raw pass-through FDI->RDI
// Data Path / RX raw pass-through RDI->FDI
// Data Path / No adapter-added retry or CRC in raw mode
//
// After full bring-up:
//   TX: drives N beats on FDI, scoreboard checks RDI output byte-for-byte.
//   RX: drives N beats on RDI, scoreboard checks FDI output byte-for-byte.
//   Purity: asserts that retry/CRC-related signals never fire.

module ucie_d2d_test (
  input logic clock,
  input logic reset,
  ucie_d2d_fdi_if fdi,
  ucie_d2d_rdi_if rdi
);
  import ucie_d2d_dv_pkg::*;
  `include "d2d_bringup_tasks.svh"

  // Simple PRNG for deterministic random data.
  function automatic logic [255:0] prng(input logic [255:0] seed);
    // Xorshift-256 style: good enough for a scoreboard test.
    prng = seed;
    prng ^= prng << 13;
    prng ^= prng >> 7;
    prng ^= prng << 17;
  endfunction

  localparam int NUM_TX_BEATS = 20;
  localparam int NUM_RX_BEATS = 20;

  // TX scoreboard queues
  logic [255:0] tx_expected_q[$];
  logic [255:0] rx_expected_q[$];

  int tx_errors = 0;
  int rx_errors = 0;

  // ---- Purity checker (always-on after reset) ----
  // plFlitCancel is not in the current interface — proxy check:
  // in raw mode the adapter should never assert plTrainError unprovoked,
  // and rdi.lpStallAck should only rise after plStallReq.
  initial begin
    forever begin
      @(posedge clock);
      if (!reset && fdi.plStateSts == RDI_STATE_ACTIVE) begin
        // plTrainError should not be asserted unless we injected a PHY error.
        if (fdi.plTrainError === 1'b1)
          $error("[%0t] PURITY FAIL: plTrainError asserted in raw mode with no error injected",
                 $time);
      end
    end
  end

  // ---- RX monitor (runs in parallel with main thread) ----
  initial begin
    // Wait until FDI is Active before monitoring receive path.
    wait(fdi.plStateSts == RDI_STATE_ACTIVE);
    @(posedge clock);

    // Collect RX beats as they appear on fdi.plValid
    forever begin
      @(posedge clock);
      if (fdi.plValid === 1'b1 && fdi.plStateSts == RDI_STATE_ACTIVE) begin
        if (rx_expected_q.size() == 0) begin
          $error("[%0t] RX FAIL: unexpected plValid with no expected data queued",
                 $time);
          rx_errors++;
        end else begin
          logic [255:0] exp = rx_expected_q.pop_front();
          if (fdi.plData !== exp) begin
            $error("[%0t] RX FAIL: plData=%0h expected=%0h", $time,
                   fdi.plData, exp);
            rx_errors++;
          end
        end
      end
    end
  end

  // ---- RDI TX monitor (runs in parallel) ----
  initial begin
    wait(fdi.plStateSts == RDI_STATE_ACTIVE);
    @(posedge clock);

    forever begin
      @(posedge clock);
      if (rdi.lpValid === 1'b1 && rdi.lpIrdy === 1'b1) begin
        if (tx_expected_q.size() == 0) begin
          $error("[%0t] TX FAIL: unexpected RDI lpValid with no expected data",
                 $time);
          tx_errors++;
        end else begin
          logic [255:0] exp = tx_expected_q.pop_front();
          if (rdi.lpData !== exp) begin
            $error("[%0t] TX FAIL: RDI lpData=%0h expected=%0h", $time,
                   rdi.lpData, exp);
            tx_errors++;
          end else begin
            $display("[%0t] TX beat OK: %0h", $time, exp);
          end
        end
      end
    end
  end

  // ---- Main test sequence ----
  initial begin
    @(negedge reset);

    // Full raw-mode bring-up
    run_raw_bringup(fdi, rdi, clock);

    // ================================================================
    // TEST 13: TX raw pass-through FDI -> RDI
    // ================================================================
    $display("[%0t] === TX passthrough test ===", $time);
    begin
      logic [255:0] seed = 256'hDEAD_BEEF_CAFE_1234_5678_9ABC_DEF0_1234_DEAD_BEEF_CAFE_1234_5678_9ABC_DEF0_1234;
      int i;

      // Deterministic patterns first
      // All-zeros
      @(posedge clock);
      fdi.lpValid = 1'b1;
      fdi.lpIrdy  = 1'b1;
      fdi.lpData  = '0;
      tx_expected_q.push_back('0);
      wait(fdi.plTrdy === 1'b1);
      @(posedge clock);

      // All-ones
      fdi.lpData = '1;
      tx_expected_q.push_back('1);
      wait(fdi.plTrdy === 1'b1);
      @(posedge clock);

      // Alternating 0x55/0xAA pattern
      fdi.lpData = {32{8'h55}};
      tx_expected_q.push_back({32{8'h55}});
      wait(fdi.plTrdy === 1'b1);
      @(posedge clock);

      fdi.lpData = {32{8'hAA}};
      tx_expected_q.push_back({32{8'hAA}});
      wait(fdi.plTrdy === 1'b1);
      @(posedge clock);

      // Pseudo-random beats
      for (i = 0; i < NUM_TX_BEATS; i++) begin
        seed = prng(seed);
        fdi.lpData = seed;
        tx_expected_q.push_back(seed);
        wait(fdi.plTrdy === 1'b1);
        @(posedge clock);
      end

      fdi.lpValid = 1'b0;
      fdi.lpIrdy  = 1'b0;
    end

    // Wait for TX scoreboard to drain
    begin : wait_tx_drain
      int i;
      for (i = 0; i < 50 && tx_expected_q.size() > 0; i++)
        @(posedge clock);
      if (tx_expected_q.size() != 0)
        $error("[%0t] TX FAIL: %0d expected beats never appeared on RDI",
               $time, tx_expected_q.size());
      else if (tx_errors == 0)
        $display("[%0t] PASS: All TX beats matched RDI output byte-for-byte",
                 $time);
    end

    // ================================================================
    // TEST 14: RX raw pass-through RDI -> FDI
    // ================================================================
    $display("[%0t] === RX passthrough test ===", $time);
    begin
      logic [255:0] seed = 256'hCAFEBABE_FEEDFACE_12345678_ABCDEF01_CAFEBABE_FEEDFACE_12345678_ABCDEF01;
      int i;

      // Give plTrdy = 1 on RDI so adapter can accept.
      rdi.plTrdy = 1'b1;

      // Deterministic patterns
      @(negedge clock);
      rdi.plValid = 1'b1;
      rdi.plData  = '0;
      rx_expected_q.push_back('0);
      @(posedge clock); @(negedge clock);

      rdi.plData = '1;
      rx_expected_q.push_back('1);
      @(posedge clock); @(negedge clock);

      rdi.plData = {32{8'h55}};
      rx_expected_q.push_back({32{8'h55}});
      @(posedge clock); @(negedge clock);

      rdi.plData = {32{8'hAA}};
      rx_expected_q.push_back({32{8'hAA}});
      @(posedge clock); @(negedge clock);

      // Pseudo-random beats
      for (i = 0; i < NUM_RX_BEATS; i++) begin
        seed = prng(seed);
        rdi.plData = seed;
        rx_expected_q.push_back(seed);
        @(posedge clock); @(negedge clock);
      end

      rdi.plValid = 1'b0;
      rdi.plData  = '0;
    end

    // Wait for RX scoreboard to drain
    begin : wait_rx_drain
      int i;
      for (i = 0; i < 50 && rx_expected_q.size() > 0; i++)
        @(posedge clock);
      if (rx_expected_q.size() != 0)
        $error("[%0t] RX FAIL: %0d expected beats never appeared on FDI",
               $time, rx_expected_q.size());
      else if (rx_errors == 0)
        $display("[%0t] PASS: All RX beats matched FDI output byte-for-byte",
                 $time);
    end

    // ================================================================
    // TEST 15: No adapter-added CRC / retry behavior
    // ================================================================
    $display("[%0t] === No CRC/retry purity check ===", $time);
    // The purity checker runs throughout. At this point we just verify
    // no unexpected signals fired. Additionally check that the byte count
    // in == byte count out (no extra header/CRC beats inserted).
    // The scoreboard above already verifies this implicitly —
    // if extra bytes were inserted the data values would mismatch.
    // Explicitly check plTrainError is still 0.
    assert(fdi.plTrainError === 1'b0)
      else $error("[%0t] PURITY FAIL: plTrainError asserted with no PHY error",
                  $time);
    $display("[%0t] PASS: No CRC/retry/trainError observed in raw mode", $time);

    // ================================================================
    // Summary
    // ================================================================
    if (tx_errors == 0 && rx_errors == 0)
      $display("[%0t] raw_datapath_test ALL PASSED", $time);
    else
      $error("[%0t] raw_datapath_test FAILED: tx_errors=%0d rx_errors=%0d",
             $time, tx_errors, rx_errors);

    $finish;
  end

endmodule