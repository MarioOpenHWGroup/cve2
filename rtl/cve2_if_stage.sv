// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Instruction Fetch Stage
 *
 * Instruction fetch unit: Selection of the next PC, and buffering (sampling) of
 * the read instruction.
 */

`include "prim_assert.sv"

module cve2_if_stage import cve2_pkg::*; #(
  parameter int unsigned DmHaltAddr        = 32'h1A110800,
  parameter int unsigned DmExceptionAddr   = 32'h1A110808,
  parameter bit          BranchPredictor   = 1'b0
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [31:0]                  boot_addr_i,              // also used for mtvec
  input  logic                         req_i,                    // instruction request control

  // instruction cache interface
  output logic                        instr_req_o,
  output logic [31:0]                 instr_addr_o,
  input  logic                        instr_gnt_i,
  input  logic                        instr_rvalid_i,
  input  logic [31:0]                 instr_rdata_i,
  input  logic                        instr_err_i,

  // output of ID stage
  output logic                        instr_valid_id_o,         // instr in IF-ID is valid
  output logic                        instr_new_id_o,           // instr in IF-ID is new
  output logic [31:0]                 instr_rdata_id_o,         // instr for ID stage
  output logic [31:0]                 instr_rdata_alu_id_o,     // replicated instr for ID stage
                                                                // to reduce fan-out
  output logic [15:0]                 instr_rdata_c_id_o,       // compressed instr for ID stage
                                                                // (mtval), meaningful only if
                                                                // instr_is_compressed_id_o = 1'b1
  output logic                        instr_is_compressed_id_o, // compressed decoder thinks this
                                                                // is a compressed instr
  output logic                        instr_bp_taken_o,         // instruction was predicted to be
                                                                // a taken branch
  output logic                        instr_fetch_err_o,        // bus error on fetch
  output logic                        instr_fetch_err_plus2_o,  // bus error misaligned
  output logic                        illegal_c_insn_id_o,      // compressed decoder thinks this
                                                                // is an invalid instr
  output logic [31:0]                 pc_if_o,
  output logic [31:0]                 pc_id_o,
  input  logic                        pmp_err_if_i,
  input  logic                        pmp_err_if_plus2_i,

  // control signals
  input  logic                        instr_valid_clear_i,      // clear instr valid bit in IF-ID
  input  logic                        pc_set_i,                 // set the PC to a new value
  input  pc_sel_e                     pc_mux_i,                 // selector for PC multiplexer
  input  logic                        nt_branch_mispredict_i,   // Not-taken branch in ID/EX was
                                                                // mispredicted (predicted taken)
  input  logic [31:0]                 nt_branch_addr_i,         // Not-taken branch address in ID/EX
  input  exc_pc_sel_e                 exc_pc_mux_i,             // selects ISR address
  input  exc_cause_e                  exc_cause,                // selects ISR address for
                                                                // vectorized interrupt lines
  // jump and branch target
  input  logic [31:0]                 branch_target_ex_i,       // branch/jump target address

  // CSRs
  input  logic [31:0]                 csr_mepc_i,               // PC to restore after handling
                                                                // the interrupt/exception
  input  logic [31:0]                 csr_depc_i,               // PC to restore after handling
                                                                // the debug request
  input  logic [31:0]                 csr_mtvec_i,              // base PC to jump to on exception
  output logic                        csr_mtvec_init_o,         // tell CS regfile to init mtvec

  // pipeline stall
  input  logic                        id_in_ready_i,            // ID stage is ready for new instr

  // misc signals
  output logic                        if_busy_o                 // IF stage is busy fetching instr
);

  logic              instr_valid_id_d, instr_valid_id_q;
  logic              instr_new_id_d, instr_new_id_q;

  // prefetch buffer related signals
  logic              prefetch_busy;
  logic              branch_req;
  logic       [31:0] fetch_addr_n;
  logic              unused_fetch_addr_n0;

  logic              fetch_valid;
  logic              fetch_ready;
  logic       [31:0] fetch_rdata;
  logic       [31:0] fetch_addr;
  logic              fetch_err;
  logic              fetch_err_plus2;

  logic [31:0]       instr_decompressed;
  logic              illegal_c_insn;
  logic              instr_is_compressed;

  logic              if_instr_valid;
  logic       [31:0] if_instr_rdata;
  logic       [31:0] if_instr_addr;
  logic              if_instr_bus_err;
  logic              if_instr_pmp_err;
  logic              if_instr_err;
  logic              if_instr_err_plus2;

  logic       [31:0] exc_pc;

  logic        [5:0] irq_id;
  logic              unused_irq_bit;

  logic              if_id_pipe_reg_we; // IF-ID pipeline reg write enable

  logic              predict_branch_taken;
  logic       [31:0] predict_branch_pc;

  cve2_pkg::pc_sel_e pc_mux_internal;

  logic        [7:0] unused_boot_addr;
  logic        [7:0] unused_csr_mtvec;

  assign unused_boot_addr = boot_addr_i[7:0];
  assign unused_csr_mtvec = csr_mtvec_i[7:0];

  // extract interrupt ID from exception cause
  assign irq_id         = {exc_cause};
  assign unused_irq_bit = irq_id[5];   // MSB distinguishes interrupts from exceptions

  // exception PC selection mux
  always_comb begin : exc_pc_mux
    unique case (exc_pc_mux_i)
      EXC_PC_EXC:     exc_pc = { csr_mtvec_i[31:8], 8'h00                    };
      EXC_PC_IRQ:     exc_pc = { csr_mtvec_i[31:8], 1'b0, irq_id[4:0], 2'b00 };
      EXC_PC_DBD:     exc_pc = DmHaltAddr;
      EXC_PC_DBG_EXC: exc_pc = DmExceptionAddr;
      default:        exc_pc = { csr_mtvec_i[31:8], 8'h00                    };
    endcase
  end

  // The Branch predictor can provide a new PC which is internal to if_stage. Only override the mux
  // select to choose this if the core isn't already trying to set a PC.
  assign pc_mux_internal =
    (BranchPredictor && predict_branch_taken && !pc_set_i) ? PC_BP : pc_mux_i;

  // fetch address selection mux
  always_comb begin : fetch_addr_mux
    unique case (pc_mux_internal)
      PC_BOOT: fetch_addr_n = { boot_addr_i[31:8], 8'h00 };
      PC_JUMP: fetch_addr_n = branch_target_ex_i;
      PC_EXC:  fetch_addr_n = exc_pc;                       // set PC to exception handler
      PC_ERET: fetch_addr_n = csr_mepc_i;                   // restore PC when returning from EXC
      PC_DRET: fetch_addr_n = csr_depc_i;
      // Without branch predictor will never get pc_mux_internal == PC_BP. We still handle no branch
      // predictor case here to ensure redundant mux logic isn't synthesised.
      PC_BP:   fetch_addr_n = BranchPredictor ? predict_branch_pc : { boot_addr_i[31:8], 8'h00 };
      default: fetch_addr_n = { boot_addr_i[31:8], 8'h00 };
    endcase
  end

  // tell CS register file to initialize mtvec on boot
  assign csr_mtvec_init_o = (pc_mux_i == PC_BOOT) & pc_set_i;

  begin : gen_prefetch_buffer
    // prefetch buffer, caches a fixed number of instructions
    cve2_prefetch_buffer #(
    ) prefetch_buffer_i (
        .clk_i               ( clk_i                      ),
        .rst_ni              ( rst_ni                     ),

        .req_i               ( req_i                      ),

        .branch_i            ( branch_req                 ),
        .branch_mispredict_i ( nt_branch_mispredict_i     ),
        .mispredict_addr_i   ( nt_branch_addr_i           ),
        .addr_i              ( {fetch_addr_n[31:1], 1'b0} ),

        .ready_i             ( fetch_ready                ),
        .valid_o             ( fetch_valid                ),
        .rdata_o             ( fetch_rdata                ),
        .addr_o              ( fetch_addr                 ),
        .err_o               ( fetch_err                  ),
        .err_plus2_o         ( fetch_err_plus2            ),

        .instr_req_o         ( instr_req_o                ),
        .instr_addr_o        ( instr_addr_o               ),
        .instr_gnt_i         ( instr_gnt_i                ),
        .instr_rvalid_i      ( instr_rvalid_i             ),
        .instr_rdata_i       ( instr_rdata_i              ),
        .instr_err_i         ( instr_err_i                ),

        .busy_o              ( prefetch_busy              )
    );
  end

  assign unused_fetch_addr_n0 = fetch_addr_n[0];

  assign branch_req  = pc_set_i | predict_branch_taken;

  assign pc_if_o     = if_instr_addr;
  assign if_busy_o   = prefetch_busy;

  // PMP errors
  // An error can come from the instruction address, or the next instruction address for unaligned,
  // uncompressed instructions.
  assign if_instr_pmp_err = pmp_err_if_i |
                            (if_instr_addr[2] & ~instr_is_compressed & pmp_err_if_plus2_i);

  // Combine bus errors and pmp errors
  assign if_instr_err = if_instr_bus_err | if_instr_pmp_err;

  // Capture the second half of the address for errors on the second part of an instruction
  assign if_instr_err_plus2 = ((if_instr_addr[2] & ~instr_is_compressed & pmp_err_if_plus2_i) |
                               fetch_err_plus2) & ~pmp_err_if_i;

  // compressed instruction decoding, or more precisely compressed instruction
  // expander
  //
  // since it does not matter where we decompress instructions, we do it here
  // to ease timing closure
  cve2_compressed_decoder compressed_decoder_i (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .valid_i        (fetch_valid & ~fetch_err),
    .instr_i        (if_instr_rdata),
    .instr_o        (instr_decompressed),
    .is_compressed_o(instr_is_compressed),
    .illegal_instr_o(illegal_c_insn)
  );

  // The ID stage becomes valid as soon as any instruction is registered in the ID stage flops.
  // Note that the current instruction is squashed by the incoming pc_set_i signal.
  // Valid is held until it is explicitly cleared (due to an instruction completing or an exception)
  assign instr_valid_id_d = (if_instr_valid & id_in_ready_i & ~pc_set_i) |
                            (instr_valid_id_q & ~instr_valid_clear_i);
  assign instr_new_id_d   = if_instr_valid & id_in_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_valid_id_q <= 1'b0;
      instr_new_id_q   <= 1'b0;
    end else begin
      instr_valid_id_q <= instr_valid_id_d;
      instr_new_id_q   <= instr_new_id_d;
    end
  end

  assign instr_valid_id_o = instr_valid_id_q;
  // Signal when a new instruction enters the ID stage (only used for RVFI signalling).
  assign instr_new_id_o   = instr_new_id_q;

  // IF-ID pipeline registers, frozen when the ID stage is stalled
  assign if_id_pipe_reg_we = instr_new_id_d;

  begin : g_instr_rdata
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        instr_rdata_id_o         <= '0;
        instr_rdata_alu_id_o     <= '0;
        instr_fetch_err_o        <= '0;
        instr_fetch_err_plus2_o  <= '0;
        instr_rdata_c_id_o       <= '0;
        instr_is_compressed_id_o <= '0;
        illegal_c_insn_id_o      <= '0;
        pc_id_o                  <= '0;
      end else if (if_id_pipe_reg_we) begin
        instr_rdata_id_o         <= instr_decompressed;
        // To reduce fan-out and help timing from the instr_rdata_id flops they are replicated.
        instr_rdata_alu_id_o     <= instr_decompressed;
        instr_fetch_err_o        <= if_instr_err;
        instr_fetch_err_plus2_o  <= if_instr_err_plus2;
        instr_rdata_c_id_o       <= if_instr_rdata[15:0];
        instr_is_compressed_id_o <= instr_is_compressed;
        illegal_c_insn_id_o      <= illegal_c_insn;
        pc_id_o                  <= pc_if_o;
      end
    end
  end

  if (BranchPredictor) begin : g_branch_predictor
    logic [31:0] instr_skid_data_q;
    logic [31:0] instr_skid_addr_q;
    logic        instr_skid_bp_taken_q;
    logic        instr_skid_valid_q, instr_skid_valid_d;
    logic        instr_skid_en;
    logic        instr_bp_taken_q, instr_bp_taken_d;

    logic        predict_branch_taken_raw;

    // ID stages needs to know if branch was predicted taken so it can signal mispredicts
    begin : g_bp_taken
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          instr_bp_taken_q <= '0;
        end else if (if_id_pipe_reg_we) begin
          instr_bp_taken_q <= instr_bp_taken_d;
        end
      end
    end

    // When branch prediction is enabled a skid buffer between the IF and ID/EX stage is introduced.
    // If an instruction in IF is predicted to be a taken branch and ID/EX is not ready the
    // instruction in IF is moved to the skid buffer which becomes the output of the IF stage until
    // the ID/EX stage accepts the instruction. The skid buffer is required as otherwise the ID/EX
    // ready signal is coupled to the instr_req_o output which produces a feedthrough path from
    // data_gnt_i -> instr_req_o (which needs to be avoided as for some interconnects this will
    // result in a combinational loop).

    assign instr_skid_en = predict_branch_taken & ~pc_set_i & ~id_in_ready_i & ~instr_skid_valid_q;

    assign instr_skid_valid_d = (instr_skid_valid_q & ~id_in_ready_i) |
                                instr_skid_en;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        instr_skid_valid_q <= 1'b0;
      end else begin
        instr_skid_valid_q <= instr_skid_valid_d;
      end
    end

    begin : g_instr_skid
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          instr_skid_bp_taken_q <= '0;
          instr_skid_data_q     <= '0;
          instr_skid_addr_q     <= '0;
        end else if (instr_skid_en) begin
          instr_skid_bp_taken_q <= predict_branch_taken;
          instr_skid_data_q     <= fetch_rdata;
          instr_skid_addr_q     <= fetch_addr;
        end
      end
    end

    cve2_branch_predict branch_predict_i (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .fetch_rdata_i(fetch_rdata),
      .fetch_pc_i   (fetch_addr),
      .fetch_valid_i(fetch_valid),

      .predict_branch_taken_o(predict_branch_taken_raw),
      .predict_branch_pc_o   (predict_branch_pc)
    );

    // If there is an instruction in the skid buffer there must be no branch prediction.
    // Instructions are only placed in the skid after they have been predicted to be a taken branch
    // so with the skid valid any prediction has already occurred.
    // Do not branch predict on instruction errors.
    assign predict_branch_taken = predict_branch_taken_raw & ~instr_skid_valid_q & ~fetch_err;

    assign if_instr_valid   = fetch_valid | (instr_skid_valid_q & ~nt_branch_mispredict_i);
    assign if_instr_rdata   = instr_skid_valid_q ? instr_skid_data_q : fetch_rdata;
    assign if_instr_addr    = instr_skid_valid_q ? instr_skid_addr_q : fetch_addr;

    // Don't branch predict on instruction error so only instructions without errors end up in the
    // skid buffer.
    assign if_instr_bus_err = ~instr_skid_valid_q & fetch_err;
    assign instr_bp_taken_d = instr_skid_valid_q ? instr_skid_bp_taken_q : predict_branch_taken;

    assign fetch_ready = id_in_ready_i & ~instr_skid_valid_q;

    assign instr_bp_taken_o = instr_bp_taken_q;

    `ASSERT(NoPredictSkid, instr_skid_valid_q |-> ~predict_branch_taken)
    `ASSERT(NoPredictIllegal, predict_branch_taken |-> ~illegal_c_insn)
  end else begin : g_no_branch_predictor
    assign instr_bp_taken_o     = 1'b0;
    assign predict_branch_taken = 1'b0;
    assign predict_branch_pc    = 32'b0;

    assign if_instr_valid = fetch_valid;
    assign if_instr_rdata = fetch_rdata;
    assign if_instr_addr  = fetch_addr;
    assign if_instr_bus_err = fetch_err;
    assign fetch_ready = id_in_ready_i;
  end

  ////////////////
  // Assertions //
  ////////////////

  // Selectors must be known/valid.
  `ASSERT_KNOWN(IbexExcPcMuxKnown, exc_pc_mux_i)

  if (BranchPredictor) begin : g_branch_predictor_asserts
    `ASSERT_IF(IbexPcMuxValid, pc_mux_internal inside {
        PC_BOOT,
        PC_JUMP,
        PC_EXC,
        PC_ERET,
        PC_DRET,
        PC_BP},
      pc_set_i)

`ifdef INC_ASSERT
    /**
     * Checks for branch prediction interface to fetch_fifo/icache
     *
     * The interface has two signals:
     * - predicted_branch_i: When set with a branch (branch_i) indicates the branch is a predicted
     *   one, it should be ignored when a branch_i isn't set.
     * - branch_mispredict_i: Indicates the previously predicted branch was mis-predicted and
     *   execution should resume with the not-taken side of the branch (i.e. continue with the PC
     *   that followed the predicted branch). This must be raised before the instruction that is
     *   made available following a predicted branch is accepted (Following a cycle with branch_i
     *   & predicted_branch_i, branch_mispredict_i can only be asserted before or on the same cycle
     *   as seeing fetch_valid & fetch_ready). When branch_mispredict_i is asserted, fetch_valid may
     *   be asserted in response. If fetch_valid is asserted on the same cycle as
     *   branch_mispredict_i this indicates the fetch_fifo/icache has the not-taken side of the
     *   branch immediately ready for use
     */
    logic        predicted_branch_live_q, predicted_branch_live_d;
    logic [31:0] predicted_branch_nt_pc_q, predicted_branch_nt_pc_d;
    logic [31:0] awaiting_instr_after_mispredict_q, awaiting_instr_after_mispredict_d;
    logic [31:0] next_pc;

    logic mispredicted, mispredicted_d, mispredicted_q;

    assign next_pc = fetch_addr + (instr_is_compressed_out ? 32'd2 : 32'd4);

    logic predicted_branch;

    // pc_set_i takes precendence over branch prediction
    assign predicted_branch = predict_branch_taken & ~pc_set_i;

    always_comb begin
      predicted_branch_live_d = predicted_branch_live_q;
      mispredicted_d          = mispredicted_q;

      if (branch_req & predicted_branch) begin
        predicted_branch_live_d = 1'b1;
        mispredicted_d          = 1'b0;
      end else if (predicted_branch_live_q) begin
        if (fetch_valid & fetch_ready) begin
          predicted_branch_live_d = 1'b0;
        end else if (nt_branch_mispredict_i) begin
          mispredicted_d = 1'b1;
        end
      end
    end

    always @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        predicted_branch_live_q <= 1'b0;
        mispredicted_q          <= 1'b0;
      end else begin
        predicted_branch_live_q <= predicted_branch_live_d;
        mispredicted_q          <= mispredicted_d;
      end
    end

    always @(posedge clk_i) begin
      if (branch_req & predicted_branch) begin
        predicted_branch_nt_pc_q <= next_pc;
      end
    end

    // Must only see mispredict after we've performed a predicted branch but before we've accepted
    // any instruction (with fetch_ready & fetch_valid) that follows that predicted branch.
    `ASSERT(MispredictOnlyImmediatelyAfterPredictedBranch,
      nt_branch_mispredict_i |-> predicted_branch_live_q)
    // Check that on mispredict we get the correct PC for the non-taken side of the branch when
    // prefetch buffer/icache makes that PC available.
    `ASSERT(CorrectPCOnMispredict,
      predicted_branch_live_q & mispredicted_d & fetch_valid |->
      fetch_addr == predicted_branch_nt_pc_q)
    // Must not signal mispredict over multiple cycles but it's possible to have back to back
    // mispredicts for different branches (core signals mispredict, prefetch buffer/icache immediate
    // has not-taken side of the mispredicted branch ready, which itself is a predicted branch,
    // following cycle core signal that that branch has mispredicted).
    `ASSERT(MispredictSingleCycle,
      nt_branch_mispredict_i & ~(fetch_valid & fetch_ready) |=> ~nt_branch_mispredict_i)
    // Note that we should never see a mispredict and an incoming branch on the same cycle.
    // The mispredict also cancels any predicted branch so overall branch_req must be low.
    `ASSERT(NoMispredBranch, nt_branch_mispredict_i |-> ~branch_req)
`endif

  end else begin : g_no_branch_predictor_asserts
    `ASSERT_IF(IbexPcMuxValid, pc_mux_internal inside {
        PC_BOOT,
        PC_JUMP,
        PC_EXC,
        PC_ERET,
        PC_DRET},
      pc_set_i)
  end

  // Boot address must be aligned to 256 bytes.
  `ASSERT(IbexBootAddrUnaligned, boot_addr_i[7:0] == 8'h00)

  // Address must not contain X when request is sent.
  `ASSERT(IbexInstrAddrUnknown, instr_req_o |-> !$isunknown(instr_addr_o))

  // Address must be word aligned when request is sent.
  `ASSERT(IbexInstrAddrUnaligned, instr_req_o |-> (instr_addr_o[1:0] == 2'b00))

endmodule
