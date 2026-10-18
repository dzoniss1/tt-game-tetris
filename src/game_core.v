/*
 * Tetris game core for the Vulkos / Tiny Tapeout game-track shell.
 * Replaces src/game_core.v. Uses the shell's x, y, active, frame.
 *
 * Buttons (active high, raw, synchronised and frame-sampled inside):
 *   left, right, rot (rotate), down (soft drop). Any button starts / restarts.
 *
 * Plain Verilog-2001: no signed types, no functions, no generate blocks,
 * no vectors wider than 20 bits (board = 20 separate 10-bit rows).
 * Game logic is serialized around ONE collision checker (16 cycles/test)
 * and runs in vertical blanking, so there is no tearing.
 */
`default_nettype none

// One board row: 10 cells. clr has priority, then shift (take row above), then set.
module tt_tetris_row (
    input  wire       clk,
    input  wire       clr,
    input  wire       shift,
    input  wire [9:0] above,
    input  wire [9:0] set,
    output reg  [9:0] q
);
  always @(posedge clk) begin
    if (clr)        q <= 10'd0;
    else if (shift) q <= above;
    else            q <= q | set;
  end
endmodule

// Stores one 10-cell row of 6-bit colours.
module tt_tetris_colour_row (
    input  wire        clk,
    input  wire        clr,
    input  wire        shift,
    input  wire [59:0] above,
    input  wire        wr,
    input  wire [3:0]  col,
    input  wire [5:0]  colour,
    output reg  [59:0] q
);
  always @(posedge clk) begin
    if (clr)
      q <= 60'd0;
    else if (shift)
      q <= above;
    else if (wr)
      q[col*6 +: 6] <= colour;
  end
endmodule

module game_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       left,
    input  wire       right,
    input  wire       rot,
    input  wire       down,
    input  wire [9:0] x,
    input  wire [9:0] y,
    input  wire       active,
    input  wire       frame,
    output wire [5:0] rgb        // {R[1:0], G[1:0], B[1:0]}
);


  wire rst = ~rst_n;

  // ------------------------------------------------------------------
  // Pixel -> board cell counters (no dividers). Board is 10x20 cells of
  // 20x20 pixels at (220,40). Registers describe the CURRENT pixel x,y.
  // ------------------------------------------------------------------
  localparam X0   = 220;
  localparam Y0   = 40;
  localparam CELL = 20;

  reg       in_x, in_y;
  reg [3:0] bx;
  reg [4:0] bxs;
  reg [4:0] by, bys;

  always @(posedge clk) begin
    if (rst) begin
      in_x <= 1'b0; in_y <= 1'b0;
      bx <= 4'd0; bxs <= 5'd0; by <= 5'd0; bys <= 5'd0;
    end else begin
      if (x == X0 - 1) begin
        in_x <= 1'b1; bx <= 4'd0; bxs <= 5'd0;
      end else if (in_x) begin
        if (bxs == CELL - 1) begin
          bxs <= 5'd0;
          if (bx == 4'd9) in_x <= 1'b0;
          else            bx <= bx + 4'd1;
        end else
          bxs <= bxs + 5'd1;
      end

      if (x == 10'd799) begin
        if (y == Y0 - 1) begin
          in_y <= 1'b1; by <= 5'd0; bys <= 5'd0;
        end else if (in_y) begin
          if (bys == CELL - 1) begin
            bys <= 5'd0;
            if (by == 5'd19) in_y <= 1'b0;
            else             by <= by + 5'd1;
          end else
            bys <= bys + 5'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Game state
  // ------------------------------------------------------------------
  localparam S_IDLE  = 3'd0,  // wait for frame tick
             S_NEXT  = 3'd1,  // pick next action (rotate, sideways, down)
             S_TRY   = 3'd2,  // run 16-cycle collision test
             S_RES   = 3'd3,  // evaluate test result
             S_LOCK  = 3'd4,  // write piece into board
             S_CLR   = 3'd5,  // clear full rows, one per cycle
             S_SPAWN = 3'd6,  // pick random piece and test spawn
             S_OVER  = 3'd7;  // title / game over: wait for button

  localparam OP_ROT = 3'd0, OP_L = 3'd1, OP_R = 3'd2, OP_D = 3'd3, OP_SPAWN = 3'd4;

  reg [2:0]  st;
  reg [2:0]  op;
  reg [1:0]  stage;           // 0 rotate, 1 sideways, 2 down
  reg [1:0]  kick;
  reg [3:0]  k;               // cell index inside 4x4 box, row-major
  reg        hit;
  reg        over;

  // Piece column is stored BIASED by +4 (real column = pxb - 4), so no
  // signed arithmetic is needed. Real range -2..9 -> pxb 2..13.
  reg [15:0] cur;             // current piece 4x4 bitmap, bit = row*4+col
  reg [2:0]  ptype;
  reg [3:0]  pxb;
  reg [4:0]  py;
  reg [15:0] t_shape;         // test candidate
  reg [3:0]  t_xb;
  reg [4:0]  t_y;

  reg [15:0] lfsr;
  reg [7:0]  lines;
  reg [3:0]  lcnt, level;
  reg [5:0]  gcnt;

   // Score: one point for each tetromino locked into the board.
  reg [9:0] score;
  reg [9:0] best_score;

  wire [9:0] score_next = score + 10'd1;

  // inputs
  reg [3:0]  in_s1, in_s2, in_prev;
  reg        want_rot, want_h, hdir, want_d, fpar;
  reg [3:0]  hcnt;

  wire in_l = in_s2[0], in_r = in_s2[1], in_rot = in_s2[2], in_d = in_s2[3];
  wire any_edge = |(in_s2 & ~in_prev);
  wire restart  = (st == S_OVER) && frame && any_edge;

  localparam DAS = 4'd12;

  wire [5:0] period = 6'd10 - {2'b00, level};
  wire       g_due  = ({1'b0, gcnt} + 7'd1) >= {1'b0, period};

  // --- tetromino bitmaps (row 0 = bits 3:0). I uses 4x4 box, others 3x3.
  reg [15:0] rom_shape;
  always @(*) begin
    case (lfsr[2:0])
      3'd0:    rom_shape = 16'h00F0; // I
      3'd1:    rom_shape = 16'h0660; // O
      3'd2:    rom_shape = 16'h0072; // T
      3'd3:    rom_shape = 16'h0036; // S
      3'd4:    rom_shape = 16'h0063; // Z
      3'd5:    rom_shape = 16'h0071; // J
      default: rom_shape = 16'h0074; // L (6); 7 is rejected at spawn
    endcase
  end

  // --- clockwise rotation: new[r][c] = old[N-1-c][r]
  wire [15:0] rot4 = { cur[3], cur[7], cur[11], cur[15], cur[2], cur[6], cur[10], cur[14], cur[1], cur[5], cur[9], cur[13], cur[0], cur[4], cur[8], cur[12] };
  wire [15:0] rot3 = { 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, cur[2], cur[6], cur[10], 1'b0, cur[1], cur[5], cur[9], 1'b0, cur[0], cur[4], cur[8] };
  wire [15:0] rotcand = (ptype == 3'd0) ? rot4 :
                        (ptype == 3'd1) ? cur  : rot3;

  // ------------------------------------------------------------------
  // Board: 20 rows of 10 cells, row 19 = bottom
  // ------------------------------------------------------------------
  wire [9:0] r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15, r16, r17, r18, r19;

  wire [59:0] cr0, cr1, cr2, cr3, cr4, cr5, cr6, cr7, cr8, cr9;
  wire [59:0] cr10, cr11, cr12, cr13, cr14, cr15, cr16, cr17, cr18, cr19;

  // The colour written into a cell comes from the piece being locked.
  wire [5:0] lock_colour =
      (ptype == 3'd0) ? 6'b100000 :
      (ptype == 3'd1) ? 6'b111101 :
      (ptype == 3'd2) ? 6'b111110 :
      (ptype == 3'd3) ? 6'b101111 :
      (ptype == 3'd4) ? 6'b101110 :
      (ptype == 3'd5) ? 6'b110110 :
                        6'b110111;

  // cell under test / lock: (t_xb + k%4, t_y + k/4)
  wire [4:0] axb = {1'b0, t_xb} + {3'b000, k[1:0]};      // biased column
  wire [5:0] ay  = {1'b0, t_y} + {4'b0000, k[3:2]};
  wire oob = (axb < 5'd4) || (axb >= 5'd14) || (ay >= 6'd20);
  wire [3:0] axr = axb[3:0] - 4'd4;                      // real column 0..9

  reg [9:0] crow;
  always @(*) begin
    case (ay[4:0])
      5'd0: crow = r0;
      5'd1: crow = r1;
      5'd2: crow = r2;
      5'd3: crow = r3;
      5'd4: crow = r4;
      5'd5: crow = r5;
      5'd6: crow = r6;
      5'd7: crow = r7;
      5'd8: crow = r8;
      5'd9: crow = r9;
      5'd10: crow = r10;
      5'd11: crow = r11;
      5'd12: crow = r12;
      5'd13: crow = r13;
      5'd14: crow = r14;
      5'd15: crow = r15;
      5'd16: crow = r16;
      5'd17: crow = r17;
      5'd18: crow = r18;
      5'd19: crow = r19;
      default: crow = 10'h3FF;
    endcase
  end
  wire cell_blk = oob | crow[axr];

  wire lock_wr  = (st == S_LOCK) && t_shape[k];
  wire do_shift = (st == S_CLR);
  wire clr_all  = rst | restart;

  wire [19:0] rdec = 20'd1 << ay[4:0];
  wire [9:0]  cdec = 10'd1 << axr;
  wire [9:0]  setm = lock_wr ? cdec : 10'd0;

  wire [19:0] full = { (&r19), (&r18), (&r17), (&r16), (&r15), (&r14), (&r13), (&r12), (&r11), (&r10), (&r9), (&r8), (&r7), (&r6), (&r5), (&r4), (&r3), (&r2), (&r1), (&r0) };
  // sfx[i]: a full row exists at row i or below (higher index)
  wire [19:0] sfx;
  assign sfx[19] = full[19];
  assign sfx[18] = |full[19:18];
  assign sfx[17] = |full[19:17];
  assign sfx[16] = |full[19:16];
  assign sfx[15] = |full[19:15];
  assign sfx[14] = |full[19:14];
  assign sfx[13] = |full[19:13];
  assign sfx[12] = |full[19:12];
  assign sfx[11] = |full[19:11];
  assign sfx[10] = |full[19:10];
  assign sfx[9]  = |full[19:9];
  assign sfx[8]  = |full[19:8];
  assign sfx[7]  = |full[19:7];
  assign sfx[6]  = |full[19:6];
  assign sfx[5]  = |full[19:5];
  assign sfx[4]  = |full[19:4];
  assign sfx[3]  = |full[19:3];
  assign sfx[2]  = |full[19:2];
  assign sfx[1]  = |full[19:1];
  assign sfx[0]  = |full[19:0];

  tt_tetris_row u0 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[0]), .above(10'd0), .set(rdec[0] ? setm : 10'd0), .q(r0));
  tt_tetris_row u1 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[1]), .above(r0), .set(rdec[1] ? setm : 10'd0), .q(r1));
  tt_tetris_row u2 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[2]), .above(r1), .set(rdec[2] ? setm : 10'd0), .q(r2));
  tt_tetris_row u3 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[3]), .above(r2), .set(rdec[3] ? setm : 10'd0), .q(r3));
  tt_tetris_row u4 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[4]), .above(r3), .set(rdec[4] ? setm : 10'd0), .q(r4));
  tt_tetris_row u5 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[5]), .above(r4), .set(rdec[5] ? setm : 10'd0), .q(r5));
  tt_tetris_row u6 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[6]), .above(r5), .set(rdec[6] ? setm : 10'd0), .q(r6));
  tt_tetris_row u7 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[7]), .above(r6), .set(rdec[7] ? setm : 10'd0), .q(r7));
  tt_tetris_row u8 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[8]), .above(r7), .set(rdec[8] ? setm : 10'd0), .q(r8));
  tt_tetris_row u9 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[9]), .above(r8), .set(rdec[9] ? setm : 10'd0), .q(r9));
  tt_tetris_row u10 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[10]), .above(r9), .set(rdec[10] ? setm : 10'd0), .q(r10));
  tt_tetris_row u11 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[11]), .above(r10), .set(rdec[11] ? setm : 10'd0), .q(r11));
  tt_tetris_row u12 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[12]), .above(r11), .set(rdec[12] ? setm : 10'd0), .q(r12));
  tt_tetris_row u13 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[13]), .above(r12), .set(rdec[13] ? setm : 10'd0), .q(r13));
  tt_tetris_row u14 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[14]), .above(r13), .set(rdec[14] ? setm : 10'd0), .q(r14));
  tt_tetris_row u15 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[15]), .above(r14), .set(rdec[15] ? setm : 10'd0), .q(r15));
  tt_tetris_row u16 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[16]), .above(r15), .set(rdec[16] ? setm : 10'd0), .q(r16));
  tt_tetris_row u17 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[17]), .above(r16), .set(rdec[17] ? setm : 10'd0), .q(r17));
  tt_tetris_row u18 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[18]), .above(r17), .set(rdec[18] ? setm : 10'd0), .q(r18));
  tt_tetris_row u19 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[19]), .above(r18), .set(rdec[19] ? setm : 10'd0), .q(r19));



  tt_tetris_colour_row c0  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[0]),  .above(60'd0), .wr(lock_wr & rdec[0]),  .col(axr), .colour(lock_colour), .q(cr0));
  tt_tetris_colour_row c1  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[1]),  .above(cr0),   .wr(lock_wr & rdec[1]),  .col(axr), .colour(lock_colour), .q(cr1));
  tt_tetris_colour_row c2  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[2]),  .above(cr1),   .wr(lock_wr & rdec[2]),  .col(axr), .colour(lock_colour), .q(cr2));
  tt_tetris_colour_row c3  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[3]),  .above(cr2),   .wr(lock_wr & rdec[3]),  .col(axr), .colour(lock_colour), .q(cr3));
  tt_tetris_colour_row c4  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[4]),  .above(cr3),   .wr(lock_wr & rdec[4]),  .col(axr), .colour(lock_colour), .q(cr4));
  tt_tetris_colour_row c5  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[5]),  .above(cr4),   .wr(lock_wr & rdec[5]),  .col(axr), .colour(lock_colour), .q(cr5));
  tt_tetris_colour_row c6  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[6]),  .above(cr5),   .wr(lock_wr & rdec[6]),  .col(axr), .colour(lock_colour), .q(cr6));
  tt_tetris_colour_row c7  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[7]),  .above(cr6),   .wr(lock_wr & rdec[7]),  .col(axr), .colour(lock_colour), .q(cr7));
  tt_tetris_colour_row c8  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[8]),  .above(cr7),   .wr(lock_wr & rdec[8]),  .col(axr), .colour(lock_colour), .q(cr8));
  tt_tetris_colour_row c9  (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[9]),  .above(cr8),   .wr(lock_wr & rdec[9]),  .col(axr), .colour(lock_colour), .q(cr9));
  tt_tetris_colour_row c10 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[10]), .above(cr9),   .wr(lock_wr & rdec[10]), .col(axr), .colour(lock_colour), .q(cr10));
  tt_tetris_colour_row c11 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[11]), .above(cr10),  .wr(lock_wr & rdec[11]), .col(axr), .colour(lock_colour), .q(cr11));
  tt_tetris_colour_row c12 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[12]), .above(cr11),  .wr(lock_wr & rdec[12]), .col(axr), .colour(lock_colour), .q(cr12));
  tt_tetris_colour_row c13 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[13]), .above(cr12),  .wr(lock_wr & rdec[13]), .col(axr), .colour(lock_colour), .q(cr13));
  tt_tetris_colour_row c14 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[14]), .above(cr13),  .wr(lock_wr & rdec[14]), .col(axr), .colour(lock_colour), .q(cr14));
  tt_tetris_colour_row c15 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[15]), .above(cr14),  .wr(lock_wr & rdec[15]), .col(axr), .colour(lock_colour), .q(cr15));
  tt_tetris_colour_row c16 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[16]), .above(cr15),  .wr(lock_wr & rdec[16]), .col(axr), .colour(lock_colour), .q(cr16));
  tt_tetris_colour_row c17 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[17]), .above(cr16),  .wr(lock_wr & rdec[17]), .col(axr), .colour(lock_colour), .q(cr17));
  tt_tetris_colour_row c18 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[18]), .above(cr17),  .wr(lock_wr & rdec[18]), .col(axr), .colour(lock_colour), .q(cr18));
  tt_tetris_colour_row c19 (.clk(clk), .clr(clr_all), .shift(do_shift & sfx[19]), .above(cr18),  .wr(lock_wr & rdec[19]), .col(axr), .colour(lock_colour), .q(cr19));


  // ------------------------------------------------------------------
  // Game FSM
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    in_s1 <= {down, rot, right, left};
    in_s2 <= in_s1;
    lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    if (rst) begin
      st <= S_OVER; op <= OP_ROT; stage <= 2'd0; kick <= 2'd0; k <= 4'd0;
      hit <= 1'b0; over <= 1'b0;
      cur <= 16'd0; ptype <= 3'd0; pxb <= 4'd4; py <= 5'd0;
      t_shape <= 16'd0; t_xb <= 4'd4; t_y <= 5'd0;
      lfsr <= 16'hACE1;
      lines <= 8'd0; lcnt <= 4'd0; level <= 4'd0; gcnt <= 6'd0;
      in_s1 <= 4'd0; in_s2 <= 4'd0; in_prev <= 4'd0;
      want_rot <= 1'b0; want_h <= 1'b0; hdir <= 1'b0; want_d <= 1'b0;
      fpar <= 1'b0; hcnt <= 4'd0;

      score <= 10'd0;
      best_score <= 10'd0;

    end else begin

      // ---- per-frame input processing (frame tick happens in IDLE/OVER)
      if (frame) begin
        in_prev  <= in_s2;
        fpar     <= ~fpar;
        want_rot <= in_rot & ~in_prev[2];

        hdir <= in_l;
        if (!(in_l | in_r)) begin
          hcnt <= 4'd0; want_h <= 1'b0;
        end else if (hcnt == 4'd0) begin
          hcnt <= 4'd1; want_h <= 1'b1;
        end else if (hcnt == DAS) begin
          hcnt <= DAS - 4'd3; want_h <= 1'b1;
        end else begin
          hcnt <= hcnt + 4'd1; want_h <= 1'b0;
        end

        gcnt   <= g_due ? 6'd0 : gcnt + 6'd1;
        want_d <= g_due | (in_d & fpar);
      end

      case (st)
        S_IDLE: if (frame) begin
          stage <= 2'd0;
          st    <= S_NEXT;
        end

        S_NEXT: begin
          case (stage)
            2'd0: begin
              if (want_rot) begin
                op <= OP_ROT; kick <= 2'd0;
                t_shape <= rotcand; t_xb <= pxb; t_y <= py;
                k <= 4'd0; hit <= 1'b0; st <= S_TRY;
              end else stage <= 2'd1;
            end
            2'd1: begin
              if (want_h) begin
                op <= hdir ? OP_L : OP_R;
                t_shape <= cur; t_xb <= hdir ? pxb - 4'd1 : pxb + 4'd1; t_y <= py;
                k <= 4'd0; hit <= 1'b0; st <= S_TRY;
              end else stage <= 2'd2;
            end
            2'd2: begin
              if (want_d) begin
                op <= OP_D;
                t_shape <= cur; t_xb <= pxb; t_y <= py + 5'd1;
                k <= 4'd0; hit <= 1'b0; st <= S_TRY;
              end else st <= S_IDLE;
            end
            default: st <= S_IDLE;
          endcase
        end

        S_TRY: begin
          if (t_shape[k] && cell_blk) hit <= 1'b1;
          k <= k + 4'd1;
          if (k == 4'd15) st <= S_RES;
        end

        S_RES: begin
          if (!hit) begin
            case (op)
              OP_ROT:   begin cur <= t_shape; pxb <= t_xb; end
              OP_L,
              OP_R:     pxb <= t_xb;
              OP_D:     begin py <= t_y; gcnt <= 6'd0; end
              default:  begin cur <= t_shape; pxb <= t_xb; py <= 5'd0; end
            endcase
            if (op == OP_SPAWN) st <= S_IDLE;
            else begin stage <= stage + 2'd1; st <= S_NEXT; end
          end else begin
            case (op)
              OP_ROT: begin
                if (kick != 2'd2) begin
                  kick <= kick + 2'd1;
                  t_xb <= (kick == 2'd0) ? pxb - 4'd1 : pxb + 4'd1;
                  k <= 4'd0; hit <= 1'b0; st <= S_TRY;
                end else begin
                  stage <= stage + 2'd1; st <= S_NEXT;
                end
              end
              OP_L, OP_R: begin stage <= stage + 2'd1; st <= S_NEXT; end
              OP_D: begin t_y <= py; k <= 4'd0; st <= S_LOCK; end
              default: begin over <= 1'b1; st <= S_OVER; end
            endcase
          end
        end

          S_LOCK: begin
          k <= k + 4'd1;
          if (k == 4'd15) begin
            st <= S_CLR;

            // Count this tetromino once, at the end of its lock operation.
            score <= score_next;

            if (score_next > best_score)
              best_score <= score_next;
          end
        end

        S_CLR: begin        // row shift handled by do_shift & sfx
          if (sfx[0]) begin
            lines <= lines + 8'd1;
            if (lcnt == 4'd9) begin
              lcnt <= 4'd0;
              if (level != 4'd8) level <= level + 4'd1;
            end else
              lcnt <= lcnt + 4'd1;
          end else
            st <= S_SPAWN;
        end

        S_SPAWN: begin
          if (lfsr[2:0] != 3'd7) begin      // reject 7: uniform over 7 pieces
            ptype   <= lfsr[2:0];
            t_shape <= rom_shape;
            t_xb    <= 4'd7;                // real column 3
            t_y     <= 5'd0;
            op      <= OP_SPAWN;
            k <= 4'd0; hit <= 1'b0; gcnt <= 6'd0;
            st <= S_TRY;
          end
        end

        default: begin      // S_OVER
          if (restart) begin
            over  <= 1'b0;
            lines <= 8'd0; lcnt <= 4'd0; level <= 4'd0; gcnt <= 6'd0;
            cur   <= 16'd0;
            st    <= S_SPAWN;
            score <= 10'd0;
          end
        end
      endcase
    end
  end
// ------------------------------------------------------------------
  // Text overlay: 5x7 bitmap font
  // ------------------------------------------------------------------
  reg [7:0] msg_char;
  reg [4:0] msg_idx;
  reg [2:0] msg_row;
  reg [4:0] glyph_row;

  wire show_msg = (st == S_OVER);

  // Message vertical position.
  wire [9:0] msg_y0 = over ? 10'd238 : 10'd222;
  wire [9:0] msg_dy = y - msg_y0;

  // Select one of the three start-message lines.
  wire [1:0] text_line =
      (msg_dy < 10'd14) ? 2'd0 :
      (msg_dy >= 10'd20 && msg_dy < 10'd34) ? 2'd1 :
      (msg_dy >= 10'd40 && msg_dy < 10'd54) ? 2'd2 :
      2'd3;

  // Center each line horizontally on the 800-pixel screen.
  // Each character slot is 16 pixels wide.
  wire [9:0] line_x0 =
      over ? 10'd252 :
      (text_line == 2'd0) ? 10'd285 :  // PRESS: 5 characters
      (text_line == 2'd1) ? 10'd245 :  // ANY BUTTON: 10 slots
      10'd260;                         // TO START: 8 slots

  wire [9:0] msg_dx = x - line_x0;

  wire [9:0] line_width =
      over ? 10'd144 :
      (text_line == 2'd0) ? 10'd80 :
      (text_line == 2'd1) ? 10'd160 :
      10'd128;

  wire [9:0] line_dy =
      (text_line == 2'd0) ? msg_dy :
      (text_line == 2'd1) ? msg_dy - 10'd20 :
      msg_dy - 10'd40;

  wire msg_area =
      show_msg &&
      (text_line != 2'd3 || over) &&
      (x >= line_x0) &&
      (x < line_x0 + line_width) &&
      (y >= msg_y0) &&
      (y < msg_y0 + (over ? 10'd14 : 10'd54));

  // Decorative panel.
  wire panel_outer =
      show_msg &&
      (x >= 10'd230) && (x < 10'd570) &&
      (y >= 10'd200) && (y < 10'd300);

  wire panel_inner =
      show_msg &&
      (x >= 10'd236) && (x < 10'd564) &&
      (y >= 10'd206) && (y < 10'd294);

  wire panel_border = panel_outer && !panel_inner;

  wire panel_accent =
      show_msg &&
      (x >= 10'd250) && (x < 10'd550) &&
      (((y >= 10'd212) && (y < 10'd214)) ||
       ((y >= 10'd286) && (y < 10'd288)));

  wire panel_corners =
      show_msg &&
      (((x >= 10'd242) && (x < 10'd260) ||
        (x >= 10'd540) && (x < 10'd558)) &&
       (((y >= 10'd218) && (y < 10'd220)) ||
        ((y >= 10'd280) && (y < 10'd282))));

  // Character selection.
  always @(*) begin
    msg_idx  = msg_dx[8:4];
    msg_row  = over ? msg_dy[3:1] : line_dy[3:1];
    msg_char = 8'd32;

    if (msg_area) begin
      if (over) begin
        case (msg_idx)
          0: msg_char = "G";
          1: msg_char = "A";
          2: msg_char = "M";
          3: msg_char = "E";
          4: msg_char = 8'd32;
          5: msg_char = "O";
          6: msg_char = "V";
          7: msg_char = "E";
          8: msg_char = "R";
          default: msg_char = 8'd32;
        endcase
      end else begin
        case (text_line)
          2'd0: begin
            case (msg_idx)
              0: msg_char = "P";
              1: msg_char = "R";
              2: msg_char = "E";
              3: msg_char = "S";
              4: msg_char = "S";
              default: msg_char = 8'd32;
            endcase
          end

          2'd1: begin
            case (msg_idx)
              0: msg_char = "A";
              1: msg_char = "N";
              2: msg_char = "Y";
              3: msg_char = 8'd32;
              4: msg_char = "B";
              5: msg_char = "U";
              6: msg_char = "T";
              7: msg_char = "T";
              8: msg_char = "O";
              9: msg_char = "N";
              default: msg_char = 8'd32;
            endcase
          end

          2'd2: begin
            case (msg_idx)
              0: msg_char = "T";
              1: msg_char = "O";
              2: msg_char = 8'd32;
              3: msg_char = "S";
              4: msg_char = "T";
              5: msg_char = "A";
              6: msg_char = "R";
              7: msg_char = "T";
              default: msg_char = 8'd32;
            endcase
          end

          default: msg_char = 8'd32;
        endcase
      end
    end
  end

  // Five bits per row, left to right.
  always @(*) begin
    glyph_row = 5'b00000;

    case (msg_char)
      "A": case (msg_row)
        0: glyph_row = 5'b01110;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b10001;
        3: glyph_row = 5'b11111;
        4: glyph_row = 5'b10001;
        5: glyph_row = 5'b10001;
        6: glyph_row = 5'b10001;
        default: glyph_row = 5'b00000;
      endcase

      "B": case (msg_row)
        0: glyph_row = 5'b11110;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b10001;
        3: glyph_row = 5'b11110;
        4: glyph_row = 5'b10001;
        5: glyph_row = 5'b10001;
        6: glyph_row = 5'b11110;
        default: glyph_row = 5'b00000;
      endcase

      "E": case (msg_row)
        0: glyph_row = 5'b11111;
        1: glyph_row = 5'b10000;
        2: glyph_row = 5'b10000;
        3: glyph_row = 5'b11110;
        4: glyph_row = 5'b10000;
        5: glyph_row = 5'b10000;
        6: glyph_row = 5'b11111;
        default: glyph_row = 5'b00000;
      endcase

      "G": case (msg_row)
        0: glyph_row = 5'b01111;
        1: glyph_row = 5'b10000;
        2: glyph_row = 5'b10000;
        3: glyph_row = 5'b10111;
        4: glyph_row = 5'b10001;
        5: glyph_row = 5'b10001;
        6: glyph_row = 5'b01111;
        default: glyph_row = 5'b00000;
      endcase

      "M": case (msg_row)
        0: glyph_row = 5'b10001;
        1: glyph_row = 5'b11011;
        2: glyph_row = 5'b10101;
        3: glyph_row = 5'b10101;
        4: glyph_row = 5'b10001;
        5: glyph_row = 5'b10001;
        6: glyph_row = 5'b10001;
        default: glyph_row = 5'b00000;
      endcase

      "N": case (msg_row)
        0: glyph_row = 5'b10001;
        1: glyph_row = 5'b11001;
        2: glyph_row = 5'b10101;
        3: glyph_row = 5'b10101;
        4: glyph_row = 5'b10101;
        5: glyph_row = 5'b10011;
        6: glyph_row = 5'b10001;
        default: glyph_row = 5'b00000;
      endcase

      "O": case (msg_row)
        0: glyph_row = 5'b01110;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b10001;
        3: glyph_row = 5'b10001;
        4: glyph_row = 5'b10001;
        5: glyph_row = 5'b10001;
        6: glyph_row = 5'b01110;
        default: glyph_row = 5'b00000;
      endcase

      "P": case (msg_row)
        0: glyph_row = 5'b11110;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b10001;
        3: glyph_row = 5'b11110;
        4: glyph_row = 5'b10000;
        5: glyph_row = 5'b10000;
        6: glyph_row = 5'b10000;
        default: glyph_row = 5'b00000;
      endcase

      "R": case (msg_row)
        0: glyph_row = 5'b11110;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b10001;
        3: glyph_row = 5'b11110;
        4: glyph_row = 5'b10100;
        5: glyph_row = 5'b10010;
        6: glyph_row = 5'b10001;
        default: glyph_row = 5'b00000;
      endcase

      "S": case (msg_row)
        0: glyph_row = 5'b01111;
        1: glyph_row = 5'b10000;
        2: glyph_row = 5'b10000;
        3: glyph_row = 5'b01110;
        4: glyph_row = 5'b00001;
        5: glyph_row = 5'b00001;
        6: glyph_row = 5'b11110;
        default: glyph_row = 5'b00000;
      endcase

      "T": case (msg_row)
        0: glyph_row = 5'b11111;
        1: glyph_row = 5'b00100;
        2: glyph_row = 5'b00100;
        3: glyph_row = 5'b00100;
        4: glyph_row = 5'b00100;
        5: glyph_row = 5'b00100;
        6: glyph_row = 5'b00100;
        default: glyph_row = 5'b00000;
      endcase

      "U": case (msg_row)
        0: glyph_row = 5'b10001;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b10001;
        3: glyph_row = 5'b10001;
        4: glyph_row = 5'b10001;
        5: glyph_row = 5'b10001;
        6: glyph_row = 5'b01110;
        default: glyph_row = 5'b00000;
      endcase

      "V": case (msg_row)
        0: glyph_row = 5'b10001;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b10001;
        3: glyph_row = 5'b10001;
        4: glyph_row = 5'b10001;
        5: glyph_row = 5'b01010;
        6: glyph_row = 5'b00100;
        default: glyph_row = 5'b00000;
      endcase

      "Y": case (msg_row)
        0: glyph_row = 5'b10001;
        1: glyph_row = 5'b10001;
        2: glyph_row = 5'b01010;
        3: glyph_row = 5'b00100;
        4: glyph_row = 5'b00100;
        5: glyph_row = 5'b00100;
        6: glyph_row = 5'b00100;
        default: glyph_row = 5'b00000;
      endcase

      default: glyph_row = 5'b00000;
    endcase
  end

   wire text_pixel = msg_area &&
                    (msg_dx[3:1] < 3'd5) &&
                    glyph_row[4 - msg_dx[3:1]];

  
  // Game Over flashing timer
reg [5:0] blink_count;
reg       blink_red;

always @(posedge clk) begin
    if (rst) begin
        blink_count <= 6'd0;
        blink_red   <= 1'b0;
    end else if (frame) begin
        if (blink_count == 6'd10) begin
            blink_count <= 6'd0;
            blink_red   <= ~blink_red;
        end else begin
            blink_count <= blink_count + 6'd1;
        end
    end
end

  // ------------------------------------------------------------------
  // Video
  // ------------------------------------------------------------------
  wire [5:0] dxs = {2'b00, bx} + 6'd4 - {2'b00, pxb};   // wraps if negative
  wire [5:0] dys = {1'b0, by} - {1'b0, py};
  wire piece_on = (dxs[5:2] == 4'd0) && (dys[5:2] == 4'd0) && cur[{dys[1:0], dxs[1:0]}];

  reg [9:0] vrow;
  always @(*) begin
    case (by)
      5'd0: vrow = r0;
      5'd1: vrow = r1;
      5'd2: vrow = r2;
      5'd3: vrow = r3;
      5'd4: vrow = r4;
      5'd5: vrow = r5;
      5'd6: vrow = r6;
      5'd7: vrow = r7;
      5'd8: vrow = r8;
      5'd9: vrow = r9;
      5'd10: vrow = r10;
      5'd11: vrow = r11;
      5'd12: vrow = r12;
      5'd13: vrow = r13;
      5'd14: vrow = r14;
      5'd15: vrow = r15;
      5'd16: vrow = r16;
      5'd17: vrow = r17;
      5'd18: vrow = r18;
      5'd19: vrow = r19;
      default: vrow = 10'd0;
    endcase
  end

 reg [59:0] vcolour_row;

  always @(*) begin
    case (by)
      5'd0:  vcolour_row = cr0;
      5'd1:  vcolour_row = cr1;
      5'd2:  vcolour_row = cr2;
      5'd3:  vcolour_row = cr3;
      5'd4:  vcolour_row = cr4;
      5'd5:  vcolour_row = cr5;
      5'd6:  vcolour_row = cr6;
      5'd7:  vcolour_row = cr7;
      5'd8:  vcolour_row = cr8;
      5'd9:  vcolour_row = cr9;
      5'd10: vcolour_row = cr10;
      5'd11: vcolour_row = cr11;
      5'd12: vcolour_row = cr12;
      5'd13: vcolour_row = cr13;
      5'd14: vcolour_row = cr14;
      5'd15: vcolour_row = cr15;
      5'd16: vcolour_row = cr16;
      5'd17: vcolour_row = cr17;
      5'd18: vcolour_row = cr18;
      5'd19: vcolour_row = cr19;
      default: vcolour_row = 60'd0;
    endcase
  end

  wire [5:0] stored_colour = vcolour_row[bx*6 +: 6];


  wire lit = vrow[bx];

  wire edge_px = (bxs == 5'd0) || (bys == 5'd0);

  reg [5:0] piece_col;
  always @(*) begin
    case (ptype)
      // 3'd0:    piece_col = 6'b001111; // I cyan
      // 3'd1:    piece_col = 6'b111100; // O yellow
      // 3'd2:    piece_col = 6'b110011; // T magenta
      // 3'd3:    piece_col = 6'b001100; // S green
      // 3'd4:    piece_col = 6'b110000; // Z red
      // 3'd5:    piece_col = 6'b000011; // J blue
      // default: piece_col = 6'b111000; // L orange

      3'd0:    piece_col = 6'b100000; // I cyan
      3'd1:    piece_col = 6'b111101; // O yellow
      3'd2:    piece_col = 6'b111110; // T magenta
      3'd3:    piece_col = 6'b101111; // S green
      3'd4:    piece_col = 6'b101110; // Z red
      3'd5:    piece_col = 6'b110110; // J blue
      default: piece_col = 6'b110111; // L orange
    endcase
  end

  // side indicators: lines (8 bits, green) and level (4 bits, yellow)
  wire in_p1 = in_y && (x >= 440) && (x < 460) && (by < 5'd8);
  wire in_p2 = in_y && (x >= 470) && (x < 490) && (by < 5'd4);
  wire p_edge = (bys == 5'd0) || (bys == CELL - 1) || (x == 440) || (x == 459)
                                                  || (x == 470) || (x == 489);

  
// Score display: S### at top left, H### at top right.
  // Four 8-pixel character slots, with a 5-pixel-high font.
  reg [7:0] score_char;
  reg [4:0] score_glyph;

  localparam SC_Y  = 45;     // top edge
  localparam SC_XL = 225;   // left field origin
  localparam SC_XR = 356;   // right field origin (= 420 - 64, flush with board right edge)
  localparam SC_W  = 64;    // 4 slots * 16 px
  localparam SC_H  = 10;    // 5 rows * 2

  wire in_sl = (x >= SC_XL) && (x < SC_XL + SC_W);
  wire in_sr = (x >= SC_XR) && (x < SC_XR + SC_W);
  wire showing_high = in_sr;

  wire [9:0] disp_dx  = showing_high ? (x - SC_XR) : (x - SC_XL);
  wire [9:0] score_dy = y - SC_Y;

  wire [1:0] disp_slot = disp_dx[5:4];    // 16 px pitch
  wire [2:0] disp_col  = disp_dx[3:1];    // 0..7, glyph uses 0..4 (x2 -> 10 px)
  wire [2:0] disp_row  = score_dy[3:1];   // 0..4 for dy 0..9

  wire score_area = (y >= SC_Y) && (y < SC_Y + SC_H) && (in_sl || in_sr);

  wire [9:0] shown_score =
      showing_high ? best_score : score;

  wire [9:0] shown_mod =
      (shown_score >= 10'd1000) ?
      (shown_score - 10'd1000) : shown_score;

  wire [9:0] hundreds_full = shown_mod / 10'd100;
  wire [9:0] tens_full     = (shown_mod / 10'd10) % 10'd10;
  wire [9:0] ones_full     = shown_mod % 10'd10;

  wire [3:0] digit_hundreds = hundreds_full[3:0];
  wire [3:0] digit_tens     = tens_full[3:0];
  wire [3:0] digit_ones     = ones_full[3:0];

  always @(*) begin
    score_char = 8'd32;

    case (disp_slot)
      2'd0: score_char = showing_high ? "H" : "S";
      2'd1: score_char = 8'd48 + {4'd0, digit_hundreds};
      2'd2: score_char = 8'd48 + {4'd0, digit_tens};
      2'd3: score_char = 8'd48 + {4'd0, digit_ones};
      default: score_char = 8'd32;
    endcase
  end

  always @(*) begin
    score_glyph = 5'b00000;

    case (score_char)
      "S": case (disp_row)
        0: score_glyph = 5'b01110;
        1: score_glyph = 5'b10000;
        2: score_glyph = 5'b01100;
        3: score_glyph = 5'b00010;
        4: score_glyph = 5'b11100;
        default: score_glyph = 5'b00000;
      endcase

      "H": case (disp_row)
        0: score_glyph = 5'b10001;
        1: score_glyph = 5'b10001;
        2: score_glyph = 5'b11111;
        3: score_glyph = 5'b10001;
        4: score_glyph = 5'b10001;
        default: score_glyph = 5'b00000;
      endcase

      "0": case (disp_row)
        0: score_glyph = 5'b01110;
        1: score_glyph = 5'b10001;
        2: score_glyph = 5'b10001;
        3: score_glyph = 5'b10001;
        4: score_glyph = 5'b01110;
        default: score_glyph = 5'b00000;
      endcase

      "1": case (disp_row)
        0: score_glyph = 5'b00100;
        1: score_glyph = 5'b01100;
        2: score_glyph = 5'b00100;
        3: score_glyph = 5'b00100;
        4: score_glyph = 5'b01110;
        default: score_glyph = 5'b00000;
      endcase

      "2": case (disp_row)
        0: score_glyph = 5'b01110;
        1: score_glyph = 5'b10001;
        2: score_glyph = 5'b00110;
        3: score_glyph = 5'b01000;
        4: score_glyph = 5'b11111;
        default: score_glyph = 5'b00000;
      endcase

      "3": case (disp_row)
        0: score_glyph = 5'b11110;
        1: score_glyph = 5'b00001;
        2: score_glyph = 5'b01110;
        3: score_glyph = 5'b00001;
        4: score_glyph = 5'b11110;
        default: score_glyph = 5'b00000;
      endcase

      "4": case (disp_row)
        0: score_glyph = 5'b10010;
        1: score_glyph = 5'b10010;
        2: score_glyph = 5'b11111;
        3: score_glyph = 5'b00010;
        4: score_glyph = 5'b00010;
        default: score_glyph = 5'b00000;
      endcase

      "5": case (disp_row)
        0: score_glyph = 5'b11111;
        1: score_glyph = 5'b10000;
        2: score_glyph = 5'b11110;
        3: score_glyph = 5'b00001;
        4: score_glyph = 5'b11110;
        default: score_glyph = 5'b00000;
      endcase

      "6": case (disp_row)
        0: score_glyph = 5'b01110;
        1: score_glyph = 5'b10000;
        2: score_glyph = 5'b11110;
        3: score_glyph = 5'b10001;
        4: score_glyph = 5'b01110;
        default: score_glyph = 5'b00000;
      endcase

      "7": case (disp_row)
        0: score_glyph = 5'b11111;
        1: score_glyph = 5'b00001;
        2: score_glyph = 5'b00010;
        3: score_glyph = 5'b00100;
        4: score_glyph = 5'b00100;
        default: score_glyph = 5'b00000;
      endcase

      "8": case (disp_row)
        0: score_glyph = 5'b01110;
        1: score_glyph = 5'b10001;
        2: score_glyph = 5'b01110;
        3: score_glyph = 5'b10001;
        4: score_glyph = 5'b01110;
        default: score_glyph = 5'b00000;
      endcase

      "9": case (disp_row)
        0: score_glyph = 5'b01110;
        1: score_glyph = 5'b10001;
        2: score_glyph = 5'b01111;
        3: score_glyph = 5'b00001;
        4: score_glyph = 5'b01110;
        default: score_glyph = 5'b00000;
      endcase

      default: score_glyph = 5'b00000;
    endcase
  end

  wire score_pixel =
      score_area &&
      (disp_col < 3'd5) &&
      score_glyph[3'd4 - disp_col];


  wire in_frame = (x >= X0 - 4) && (x < X0 + 10*CELL + 4) &&
                  (y >= Y0 - 4) && (y < Y0 + 20*CELL + 4);

  reg [5:0] rgb6;
  always @(*) begin
    rgb6 = 6'b000000;
    if (in_x && in_y) begin
      if (edge_px)
        rgb6 = (lit || piece_on) ? 6'b000000 : 6'b000000;
      else if (piece_on)
        rgb6 = piece_col;
      else if (lit)
        rgb6 = over ? 6'b101010 : stored_colour;
    end else if (in_frame) begin
      rgb6 = 6'b101010;
    // end else if (in_p1) begin
    //   rgb6 = p_edge ? 6'b000000 : (lines[by[2:0]] ? 6'b001100 : 6'b010101);
    // end else if (in_p2) begin
    //   rgb6 = p_edge ? 6'b000000 : (level[by[1:0]] ? 6'b111100 : 6'b010101);
    end

    if (score_pixel)
      rgb6 = 6'b111111;

    if (text_pixel) begin
      if (over)
        rgb6 = blink_red ? 6'b110000 : 6'b111111;
      else
        rgb6 = 6'b111111;
    end
  end

  assign rgb = active ? rgb6 : 6'b000000;
  
  
endmodule
