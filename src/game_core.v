/*
 * Tetris game core for the Vulkos / Tiny Tapeout game-track shell,
 * area-optimised (fits a 1x2 tile).
 *
 * Inputs (active high, sampled once per frame): left, right, rot (rotate),
 * down (one row down). Each acts once per flip (or per press, press_mode = 1).
 * Any input starts / restarts.
 *
 * Area tricks:
 *  - The 10x20 board is ONE shift register of 20 rows that rotates by one row
 *    every clock (a full turn every 20 clocks). Its flops need no enable and
 *    no read mux: whatever row is at the head is read, and the row fed back
 *    in at the tail is where writes happen. The row at the head is the VGA
 *    x position modulo 20 (rows counted from the bottom), so it costs nothing,
 *    and the row above it is always the next register in the chain.
 *  - All board work runs serially in vertical blanking, straight on the
 *    head: collision test and lock one cell at a time as its row passes, and
 *    line clearing as one turn that copies each row from the one above it,
 *    from the lowest full row up. No row buffer is needed; the video keeps
 *    just one bit per cell.
 *  - Piece shapes come from a small ROM indexed by type and rotation, so the
 *    current and the candidate piece are just (type, rot, x, y).
 *  - The VGA position comes in 20-pixel cells (vga_cells.v), so pixel -> cell
 *    is plain subtraction of small numbers. The score counts in BCD, so no
 *    dividers.
 *  - Each cell keeps the 3-bit type of the piece that locked there, so blocks
 *    keep their colour until game over.
 *
 * Screen: board 200x400 at (220,40) in 20x20 cells, 4-pixel grey frame,
 * score S### and best H### above the board.
 */
`default_nettype none

// Piece bitmap ROM: 4x4 box, bit = row*4 + col, row 0 at the top.
// Rotations are clockwise; I turns in its 4x4 box, O does not turn, the
// others turn in the top-left 3x3 box.
module tt_tetro_rom (
    input  wire [2:0] t,
    input  wire [1:0] r,
    input  wire [3:0] idx,
    output wire       on
);
  reg [15:0] s;
  always @(*) begin
    case ({t, r})
      5'd0 : s = 16'h00F0;  // I
      5'd1 : s = 16'h4444;
      5'd2 : s = 16'h0F00;
      5'd3 : s = 16'h2222;
      5'd4 : s = 16'h0660;  // O
      5'd5 : s = 16'h0660;
      5'd6 : s = 16'h0660;
      5'd7 : s = 16'h0660;
      5'd8 : s = 16'h0072;  // T
      5'd9 : s = 16'h0262;
      5'd10: s = 16'h0270;
      5'd11: s = 16'h0232;
      5'd12: s = 16'h0036;  // S
      5'd13: s = 16'h0462;
      5'd14: s = 16'h0360;
      5'd15: s = 16'h0231;
      5'd16: s = 16'h0063;  // Z
      5'd17: s = 16'h0264;
      5'd18: s = 16'h0630;
      5'd19: s = 16'h0132;
      5'd20: s = 16'h0071;  // J
      5'd21: s = 16'h0226;
      5'd22: s = 16'h0470;
      5'd23: s = 16'h0322;
      5'd24: s = 16'h0074;  // L
      5'd25: s = 16'h0622;
      5'd26: s = 16'h0170;
      5'd27: s = 16'h0223;
      default: s = 16'h0000;
    endcase
  end
  assign on = s[idx];
endmodule

// 5x5 font. Codes: 0-9 digits (0 is also the letter O), 10 A, 11 B, 12 E,
// 13 G, 14 H, 15 M, 16 N, 17 P, 18 R, 19 S, 20 T, 21 U, 22 V, 23 Y, else blank.
module tt_font_rom (
    input  wire [4:0] ch,
    input  wire [2:0] row,
    input  wire [2:0] col,
    output wire       on
);
  reg [4:0] b;
  always @(*) begin
    case (ch)
      5'd0 : case (row) 3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001; 3'd3: b = 5'b10001; 3'd4: b = 5'b01110; default: b = 5'b00000; endcase
      5'd1 : case (row) 3'd0: b = 5'b00100; 3'd1: b = 5'b01100; 3'd2: b = 5'b00100; 3'd3: b = 5'b00100; 3'd4: b = 5'b01110; default: b = 5'b00000; endcase
      5'd2 : case (row) 3'd0: b = 5'b11110; 3'd1: b = 5'b00001; 3'd2: b = 5'b01110; 3'd3: b = 5'b10000; 3'd4: b = 5'b11111; default: b = 5'b00000; endcase
      5'd3 : case (row) 3'd0: b = 5'b11110; 3'd1: b = 5'b00001; 3'd2: b = 5'b01110; 3'd3: b = 5'b00001; 3'd4: b = 5'b11110; default: b = 5'b00000; endcase
      5'd4 : case (row) 3'd0: b = 5'b10010; 3'd1: b = 5'b10010; 3'd2: b = 5'b11111; 3'd3: b = 5'b00010; 3'd4: b = 5'b00010; default: b = 5'b00000; endcase
      5'd5 : case (row) 3'd0: b = 5'b11111; 3'd1: b = 5'b10000; 3'd2: b = 5'b11110; 3'd3: b = 5'b00001; 3'd4: b = 5'b11110; default: b = 5'b00000; endcase
      5'd6 : case (row) 3'd0: b = 5'b01110; 3'd1: b = 5'b10000; 3'd2: b = 5'b11110; 3'd3: b = 5'b10001; 3'd4: b = 5'b01110; default: b = 5'b00000; endcase
      5'd7 : case (row) 3'd0: b = 5'b11111; 3'd1: b = 5'b00001; 3'd2: b = 5'b00010; 3'd3: b = 5'b00100; 3'd4: b = 5'b00100; default: b = 5'b00000; endcase
      5'd8 : case (row) 3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b01110; 3'd3: b = 5'b10001; 3'd4: b = 5'b01110; default: b = 5'b00000; endcase
      5'd9 : case (row) 3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b01111; 3'd3: b = 5'b00001; 3'd4: b = 5'b01110; default: b = 5'b00000; endcase
      5'd10: case (row) 3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b11111; 3'd3: b = 5'b10001; 3'd4: b = 5'b10001; default: b = 5'b00000; endcase
      5'd11: case (row) 3'd0: b = 5'b11110; 3'd1: b = 5'b10001; 3'd2: b = 5'b11110; 3'd3: b = 5'b10001; 3'd4: b = 5'b11110; default: b = 5'b00000; endcase
      5'd12: case (row) 3'd0: b = 5'b11111; 3'd1: b = 5'b10000; 3'd2: b = 5'b11110; 3'd3: b = 5'b10000; 3'd4: b = 5'b11111; default: b = 5'b00000; endcase
      5'd13: case (row) 3'd0: b = 5'b01111; 3'd1: b = 5'b10000; 3'd2: b = 5'b10011; 3'd3: b = 5'b10001; 3'd4: b = 5'b01111; default: b = 5'b00000; endcase
      5'd14: case (row) 3'd0: b = 5'b10001; 3'd1: b = 5'b10001; 3'd2: b = 5'b11111; 3'd3: b = 5'b10001; 3'd4: b = 5'b10001; default: b = 5'b00000; endcase
      5'd15: case (row) 3'd0: b = 5'b10001; 3'd1: b = 5'b11011; 3'd2: b = 5'b10101; 3'd3: b = 5'b10001; 3'd4: b = 5'b10001; default: b = 5'b00000; endcase
      5'd16: case (row) 3'd0: b = 5'b10001; 3'd1: b = 5'b11001; 3'd2: b = 5'b10101; 3'd3: b = 5'b10011; 3'd4: b = 5'b10001; default: b = 5'b00000; endcase
      5'd17: case (row) 3'd0: b = 5'b11110; 3'd1: b = 5'b10001; 3'd2: b = 5'b11110; 3'd3: b = 5'b10000; 3'd4: b = 5'b10000; default: b = 5'b00000; endcase
      5'd18: case (row) 3'd0: b = 5'b11110; 3'd1: b = 5'b10001; 3'd2: b = 5'b11110; 3'd3: b = 5'b10010; 3'd4: b = 5'b10001; default: b = 5'b00000; endcase
      5'd19: case (row) 3'd0: b = 5'b01111; 3'd1: b = 5'b10000; 3'd2: b = 5'b01110; 3'd3: b = 5'b00001; 3'd4: b = 5'b11110; default: b = 5'b00000; endcase
      5'd20: case (row) 3'd0: b = 5'b11111; 3'd1: b = 5'b00100; 3'd2: b = 5'b00100; 3'd3: b = 5'b00100; 3'd4: b = 5'b00100; default: b = 5'b00000; endcase
      5'd21: case (row) 3'd0: b = 5'b10001; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001; 3'd3: b = 5'b10001; 3'd4: b = 5'b01110; default: b = 5'b00000; endcase
      5'd22: case (row) 3'd0: b = 5'b10001; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001; 3'd3: b = 5'b01010; 3'd4: b = 5'b00100; default: b = 5'b00000; endcase
      5'd23: case (row) 3'd0: b = 5'b10001; 3'd1: b = 5'b01010; 3'd2: b = 5'b00100; 3'd3: b = 5'b00100; 3'd4: b = 5'b00100; default: b = 5'b00000; endcase
      default: b = 5'b00000;
    endcase
  end
  assign on = (col < 3'd5) && b[3'd4 - col];
endmodule

module game_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       left,
    input  wire       right,
    input  wire       rot,
    input  wire       down,
    input  wire       press_mode,  // 0: act on every switch flip, 1: act on press only
    input  wire [5:0] xh,        // x = xh*20 + xl
    input  wire [4:0] xl,
    input  wire [4:0] yh,        // y = yh*20 + yl
    input  wire [4:0] yl,
    input  wire       active,
    input  wire       frame,
    output wire [5:0] rgb        // {R[1:0], G[1:0], B[1:0]}
);

  wire rst = ~rst_n;

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------
  localparam S_OVER  = 4'd0,   // title / game over: wait for button
             S_IDLE  = 4'd1,   // wait for frame tick
             S_NEXT  = 4'd2,   // pick next action (rotate, sideways, down)
             S_TEST  = 4'd3,   // test the candidate, one cell at a time
             S_RES   = 4'd4,   // test passed: move the piece
             S_HIT   = 4'd5,   // test failed: kick, give up, lock or game over
             S_LOCK  = 4'd6,   // write the piece into the board, one cell at a time
             S_CWAIT = 4'd7,   // line clear: wait for the bottom row
             S_CPASS = 4'd8,   // line clear: one turn that drops the lowest full row
             S_SPAWN = 4'd9,   // pick random piece and test spawn
             S_CLR1  = 4'd10,  // restart: wait for the bottom row
             S_CLR2  = 4'd11;  // restart: one turn writing empty rows

  // The action being tried. In a frame they are tried in this order.
  localparam OP_ROT = 2'd0, OP_H = 2'd1, OP_D = 2'd2, OP_NONE = 2'd3;

  reg [3:0]  st;
  reg [1:0]  op;
  reg [1:0]  kick;
  reg [3:0]  k;               // cell index inside 4x4 box, row-major
  reg        over;
  reg        flag;            // S_CPASS: a full row was dropped in this turn

  // Board rows are numbered from the BOTTOM (row 0) up to 19. pu is the
  // board row of the top row of the piece's 4x4 box. The piece column px
  // is stored modulo 16, so -2 is 14: every cell column then comes out
  // modulo 16 too, and any value >= 10 is outside the board.
  reg [2:0]  ptype;
  reg [1:0]  prot;
  reg [3:0]  px;
  reg [4:0]  pu;

  reg [7:0]  lfsr;
  reg [3:0]  lcnt, gcnt;
  reg [3:0]  spd;             // frames per gravity step - 1: 9 at level 0, down to 1

  // Score: one point for each tetromino locked into the board, 3 BCD digits.
  reg [11:0] score;
  reg [11:0] best_score;

  // Inputs are sampled once per frame. One clock later (tick) the frame
  // counters update, and the FSM starts on the clock after that, so every
  // want_* below is stable while the FSM runs.
  // Each input acts ONCE per event, never by being held: an event is every
  // flip of the input (switches, VGA Playground keys) or, with press_mode,
  // only a press (push buttons).
  reg [3:0]  in_s, in_prev;
  reg        mode;
  reg        tick;
  reg [3:0]  fcnt;            // frame counter: bit 3 blink

  wire [3:0] ev       = mode ? (in_s & ~in_prev) : (in_s ^ in_prev);
  wire       restart  = (st == S_OVER) && tick && (|ev);

  wire hdir     = ev[0];                      // left wins if both
  wire want_rot = ev[2];
  wire want_h   = ev[0] | ev[1];
  wire want_d   = (gcnt == 4'd0) || ev[3];
  wire want     = (op == OP_ROT) ? want_rot : (op == OP_H) ? want_h : want_d;

  // ------------------------------------------------------------------
  // Board: 20 rows of 10 cells in a chain of row registers (a shift
  // register) that turns by one row every clock. The last one (head) holds
  // board row xl; the one before it holds the row above. Each cell holds a
  // 3-bit code, 0 = empty or piece type + 1, kept as three 10-bit bit planes
  // (a = bit 0, b = bit 1, c = bit 2), because the Vulkos simulator has no
  // wide vectors. fb_* is written back as the new value of the head row.
  // ------------------------------------------------------------------
  reg  [9:0] a0, a1, a2, a3, a4, a5, a6, a7, a8, a9;
  reg  [9:0] a10, a11, a12, a13, a14, a15, a16, a17, a18, a19;
  reg  [9:0] b0, b1, b2, b3, b4, b5, b6, b7, b8, b9;
  reg  [9:0] b10, b11, b12, b13, b14, b15, b16, b17, b18, b19;
  reg  [9:0] c0, c1, c2, c3, c4, c5, c6, c7, c8, c9;
  reg  [9:0] c10, c11, c12, c13, c14, c15, c16, c17, c18, c19;
  reg  [9:0] fb_a, fb_b, fb_c;
  wire [9:0] head     = a19 | b19 | c19;              // occupied cells of the head row
  wire       full_now = &head;

  always @(posedge clk) begin
    a0  <= fb_a; a1  <= a0; a2  <= a1; a3  <= a2; a4  <= a3;
    a5  <= a4; a6  <= a5; a7  <= a6; a8  <= a7; a9  <= a8;
    a10 <= a9; a11 <= a10; a12 <= a11; a13 <= a12; a14 <= a13;
    a15 <= a14; a16 <= a15; a17 <= a16; a18 <= a17; a19 <= a18;
    b0  <= fb_b; b1  <= b0; b2  <= b1; b3  <= b2; b4  <= b3;
    b5  <= b4; b6  <= b5; b7  <= b6; b8  <= b7; b9  <= b8;
    b10 <= b9; b11 <= b10; b12 <= b11; b13 <= b12; b14 <= b13;
    b15 <= b14; b16 <= b15; b17 <= b16; b18 <= b17; b19 <= b18;
    c0  <= fb_c; c1  <= c0; c2  <= c1; c3  <= c2; c4  <= c3;
    c5  <= c4; c6  <= c5; c7  <= c6; c8  <= c7; c9  <= c8;
    c10 <= c9; c11 <= c10; c12 <= c11; c13 <= c12; c14 <= c13;
    c15 <= c14; c16 <= c15; c17 <= c16; c18 <= c17; c19 <= c18;
  end

  // Candidate position for the current action. The lock and spawn use
  // OP_NONE, so the candidate is the current piece.
  wire [1:0] crot = prot + {1'b0, op == OP_ROT};
  wire [3:0] cpx  = ((op == OP_H && hdir)  || (op == OP_ROT && kick == 2'd1)) ? px - 4'd1 :
                    ((op == OP_H && !hdir) || (op == OP_ROT && kick == 2'd2)) ? px + 4'd1 : px;
  wire [4:0] cpu  = pu - {4'd0, op == OP_D};

  // cell under test / lock: column cpx + k%4, board row cpu - k/4
  wire [5:0] ay      = {1'b0, cpu} - {4'd0, k[3:2]};
  wire       row_oob = ay[5];                 // below the bottom
  wire [3:0] col     = cpx + {2'd0, k[1:0]};

  // ------------------------------------------------------------------
  // Pixel -> board cell. Board columns at x 220..419, rows at y 40..439.
  // ------------------------------------------------------------------
  wire [5:0] cx       = xh - 6'd11;
  wire [4:0] cy       = yh - 5'd2;            // board row from the top
  wire       in_board = (cx < 6'd10) && (cy < 5'd20);
  wire [3:0] bx       = cx[3:0];
  wire [3:0] bxn      = xh[3:0] - 4'd10;      // column of the next cell
  wire [4:0] bu       = 5'd21 - yh;           // board row from the bottom

  // The video owns the shared row compare and cell mux while the FSM waits.
  wire vid = (st == S_IDLE) || (st == S_OVER);

  wire       at_row = (xl == (vid ? bu : ay[4:0]));
  wire [3:0] cidx   = vid ? bxn : col;
  wire       cin    = (cidx < 4'd10);
  wire       hbit   = cin && head[cidx];
  wire [2:0] hcode  = cin ? {c19[cidx], b19[cidx], a19[cidx]} : 3'd0;

  wire [3:0] dxs = bx - px;
  wire [4:0] dys = pu - bu;

  wire tbit;
  tt_tetro_rom rom (
      .t(ptype),
      .r(crot),                       // op is OP_NONE while vid, so crot == prot
      .idx(vid ? {dys[1:0], dxs[1:0]} : k),
      .on(tbit)
  );

  wire lock_wr  = (st == S_LOCK) && tbit && at_row;
  wire shift_dn = flag || full_now;           // S_CPASS: copy rows down from here on

  wire [2:0] code    = ptype + 3'd1;             // what a locked cell stores
  wire [9:0] onehot  = 10'd1 << col;
  wire       clr_all = rst || (st == S_OVER && !over) || st == S_CLR2;
  wire       mv_dn   = (st == S_CPASS) && shift_dn;
  wire       top     = (xl == 5'd19);

  always @(*) begin
    if (clr_all) begin                                  // clear board
      fb_a = 10'd0; fb_b = 10'd0; fb_c = 10'd0;
    end else if (lock_wr) begin                         // set one piece cell
      fb_a = a19 | (code[0] ? onehot : 10'd0);
      fb_b = b19 | (code[1] ? onehot : 10'd0);
      fb_c = c19 | (code[2] ? onehot : 10'd0);
    end else if (mv_dn) begin                           // row above moves down
      fb_a = top ? 10'd0 : a18;
      fb_b = top ? 10'd0 : b18;
      fb_c = top ? 10'd0 : c18;
    end else begin
      fb_a = a19; fb_b = b19; fb_c = c19;
    end
  end

  // Video: the cell of the next column is read when its row passes the
  // head, and shown from the next cell's first pixel (a black grid line).
  reg [2:0] ncode, ccode;
  always @(posedge clk) begin
    if (vid && at_row) ncode <= hcode;
    if (xl == 5'd0)    ccode <= ncode;
  end

  // BCD increment, saturating at 999.
  wire [3:0]  s0 = score[3:0], s1 = score[7:4], s2 = score[11:8];
  wire        bcd_c0 = (s0 == 4'd9);
  wire        bcd_c1 = bcd_c0 && (s1 == 4'd9);
  wire        smax = bcd_c1 && (s2 == 4'd9);
  wire [11:0] score_next = smax ? score :
                           { bcd_c1 ? s2 + 4'd1 : s2,
                             bcd_c0 ? (bcd_c1 ? 4'd0 : s1 + 4'd1) : s1,
                             bcd_c0 ? 4'd0 : s0 + 4'd1 };

  // A cell is done when it is empty in the box, or its row is at the head
  // (test: and it is free; lock: it is written now).
  wire cell_done = !tbit || at_row;
  wire last_cell = (k == 4'd15);

  // ------------------------------------------------------------------
  // Game FSM
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    tick <= frame;
    lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

    if (rst) begin
      st <= S_OVER; over <= 1'b0;
      lfsr <= 8'hA5;
      lcnt <= 4'd0; spd <= 4'd9; gcnt <= 4'd0;
      in_s <= 4'd0; in_prev <= 4'd0; mode <= 1'b0;
      fcnt <= 4'd0;
      score <= 12'd0;
      best_score <= 12'd0;
    end else begin

      // ---- per-frame input processing (in IDLE/OVER)
      if (frame) begin
        in_s    <= {down, rot, right, left};
        in_prev <= in_s;
        mode    <= press_mode;
      end
      if (tick) begin
        fcnt <= fcnt + 4'd1;
        gcnt <= (gcnt >= spd) ? 4'd0 : gcnt + 4'd1;
      end

      case (st)
        S_IDLE: if (tick) begin
          op <= OP_ROT;
          st <= S_NEXT;
        end

        S_NEXT: begin
          k <= 4'd0; kick <= 2'd0;
          if (op == OP_NONE) st <= S_IDLE;
          else if (want)     st <= S_TEST;
          else               op <= op + 2'd1;
        end

        S_TEST: begin
          if (tbit && (row_oob || !cin || (at_row && hbit)))
            st <= S_HIT;
          else if (cell_done) begin
            k <= k + 4'd1;
            if (last_cell) st <= S_RES;
          end
        end

        S_RES: begin
          prot <= crot; px <= cpx; pu <= cpu;
          if (op == OP_D) gcnt <= 4'd0;
          if (op == OP_NONE) st <= S_IDLE;
          else begin op <= op + 2'd1; st <= S_NEXT; end
        end

        S_HIT: begin
          k <= 4'd0;
          case (op)
            OP_ROT: begin
              if (kick != 2'd2) begin
                kick <= kick + 2'd1;
                st   <= S_TEST;
              end else begin
                op <= op + 2'd1; st <= S_NEXT;
              end
            end
            OP_D:    begin op <= OP_NONE; st <= S_LOCK; end
            OP_NONE: begin over <= 1'b1; st <= S_OVER; end
            default: begin op <= op + 2'd1; st <= S_NEXT; end
          endcase
        end

        S_LOCK: if (cell_done) begin
          k <= k + 4'd1;
          if (last_cell) begin
            // Count this tetromino once, at the end of its lock operation.
            score <= score_next;
            if (score == best_score) best_score <= score_next;
            st <= S_CWAIT;
          end
        end

        S_CWAIT: if (xl == 5'd19) begin flag <= 1'b0; st <= S_CPASS; end

        S_CPASS: begin
          if (full_now) flag <= 1'b1;
          if (xl == 5'd19) begin
            flag <= 1'b0;
            if (shift_dn) begin               // a row was dropped: count it, go again
              if (lcnt == 4'd9) begin
                lcnt <= 4'd0;
                if (spd != 4'd1) spd <= spd - 4'd1;
              end else
                lcnt <= lcnt + 4'd1;
            end else
              st <= S_SPAWN;
          end
        end

        S_SPAWN: begin
          if (lfsr[2:0] != 3'd7) begin      // reject 7: uniform over 7 pieces
            ptype <= lfsr[2:0];
            prot  <= 2'd0;
            px    <= 4'd3;
            pu    <= 5'd19;
            op    <= OP_NONE;
            k <= 4'd0; gcnt <= 4'd0;
            st <= S_TEST;
          end
        end

        S_CLR1: if (xl == 5'd19) st <= S_CLR2;
        S_CLR2: if (xl == 5'd19) st <= S_SPAWN;

        default: begin      // S_OVER
          if (restart) begin
            over  <= 1'b0;
            lcnt  <= 4'd0; spd <= 4'd9; gcnt <= 4'd0;
            score <= 12'd0;
            st    <= S_CLR1;
          end
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Text: score row above the board, title / game over over the board.
  // Characters sit on the board's 20-pixel columns (cx), one line per cell
  // row; a glyph is 5x5 drawn 2x, in the top-left 10x10 of its cell.
  // ------------------------------------------------------------------
  wire       title = (st == S_OVER) && !over;
  wire       l_sc  = (yh == 5'd1);                // y 20..39
  wire       l_t0  = title && (yh == 5'd11);      // PRESS       y 220
  wire       l_t1  = title && (yh == 5'd12);      // ANY BUTTON  y 240
  wire       l_go  = over  && (yh == 5'd12);      // GAME OVER   y 240
  wire       l_t2  = title && (yh == 5'd13);      // TO START    y 260

  reg [4:0] ch;
  always @(*) begin
    ch = 5'd31;
    if (l_sc) begin
      case (cx)
        6'd0: ch = 5'd19;                       // S
        6'd1: ch = {1'b0, score[11:8]};
        6'd2: ch = {1'b0, score[7:4]};
        6'd3: ch = {1'b0, score[3:0]};
        6'd6: ch = 5'd14;                       // H
        6'd7: ch = {1'b0, best_score[11:8]};
        6'd8: ch = {1'b0, best_score[7:4]};
        6'd9: ch = {1'b0, best_score[3:0]};
        default: ch = 5'd31;
      endcase
    end else if (l_t0) begin
      case (cx)                               // PRESS
        6'd3: ch = 5'd17; 6'd4: ch = 5'd18; 6'd5: ch = 5'd12; 6'd6: ch = 5'd19; 6'd7: ch = 5'd19;
        default: ch = 5'd31;
      endcase
    end else if (l_t1) begin
      case (cx)                               // ANY BUTTON
        6'd0: ch = 5'd10; 6'd1: ch = 5'd16; 6'd2: ch = 5'd23;
        6'd4: ch = 5'd11; 6'd5: ch = 5'd21; 6'd6: ch = 5'd20; 6'd7: ch = 5'd20; 6'd8: ch = 5'd0; 6'd9: ch = 5'd16;
        default: ch = 5'd31;
      endcase
    end else if (l_t2) begin
      case (cx)                               // TO START
        6'd1: ch = 5'd20; 6'd2: ch = 5'd0;
        6'd4: ch = 5'd19; 6'd5: ch = 5'd20; 6'd6: ch = 5'd10; 6'd7: ch = 5'd18; 6'd8: ch = 5'd20;
        default: ch = 5'd31;
      endcase
    end else if (l_go) begin
      case (cx)                               // GAME OVER
        6'd1: ch = 5'd13; 6'd2: ch = 5'd10; 6'd3: ch = 5'd15; 6'd4: ch = 5'd12;
        6'd6: ch = 5'd0;  6'd7: ch = 5'd22; 6'd8: ch = 5'd12; 6'd9: ch = 5'd18;
        default: ch = 5'd31;
      endcase
    end
  end

  wire glyph_on;
  tt_font_rom font (.ch(ch), .row(yl[3:1]), .col(xl[3:1]), .on(glyph_on));
  wire text_pixel = glyph_on && !xl[4] && !yl[4];  // font rows 5..7 are blank

  // ------------------------------------------------------------------
  // Video
  // ------------------------------------------------------------------
  wire piece_on = (st != S_OVER) && (dxs[3:2] == 2'd0) && (dys[4:2] == 3'd0) && tbit;

  // One palette by piece type, for the falling piece and the locked cells.
  reg [5:0] pal;
  always @(*) begin
    case (piece_on ? ptype : ccode - 3'd1)
      3'd0:    pal = 6'b100000;
      3'd1:    pal = 6'b111101;
      3'd2:    pal = 6'b111110;
      3'd3:    pal = 6'b101111;
      3'd4:    pal = 6'b101110;
      3'd5:    pal = 6'b110110;
      default: pal = 6'b110111;
    endcase
  end

  wire edge_px  = (xl == 5'd0) || (yl == 5'd0);
  // 4-pixel frame: the last 4 pixels of the cell before the board, and the
  // first 4 of the cell after it, in both directions.
  wire in_frame = ((cx < 6'd10) || (cx == 6'd63 && xl >= 5'd16) || (cx == 6'd10 && xl < 5'd4)) &&
                  ((cy < 5'd20) || (cy == 5'd31 && yl >= 5'd16) || (cy == 5'd20 && yl < 5'd4));

  wire [5:0] board_px = edge_px  ? 6'b000000 :
                        piece_on ? pal :
                        (ccode != 3'd0) ? (over ? 6'b101010 : pal) : 6'b000000;

  wire [5:0] rgb6 = text_pixel ? ((l_go && fcnt[3]) ? 6'b110000 : 6'b111111) :
                    in_board   ? board_px :
                    in_frame   ? 6'b101010 : 6'b000000;

  assign rgb = active ? rgb6 : 6'b000000;

endmodule
