// Tiny Tapeout top for the Tetris core. Same as the given game shell, except it
// also passes ui_in[2] (rotate) and ui_in[3] (down) to the core, and the VGA
// position comes in 20-pixel cells (vga_cells.v) instead of plain x, y.
`default_nettype none

module tt_um_dzoniss1_game_paddle_and_ball (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    wire        hsync, vsync, active, frame;
    wire [5:0]  xh;
    wire [4:0]  xl, yh, yl;
    wire [5:0]  rgb;

    vga_cells vga (.clk(clk), .rst_n(rst_n), .hsync(hsync), .vsync(vsync), .active(active), .frame(frame),
                   .xh(xh), .xl(xl), .yh(yh), .yl(yl));

    game_core core (
        .clk(clk), .rst_n(rst_n),
        .left(ui_in[0]), .right(ui_in[1]), .rot(ui_in[2]), .down(ui_in[3]), .press_mode(ui_in[4]),
        .xh(xh), .xl(xl), .yh(yh), .yl(yl), .active(active), .frame(frame),
        .rgb(rgb)
    );

    // TinyVGA PMOD pin order: {hsync, B0, G0, R0, vsync, B1, G1, R1}
    assign uo_out = {hsync, rgb[0], rgb[2], rgb[4], vsync, rgb[1], rgb[3], rgb[5]};
    assign uio_out = 8'd0;
    assign uio_oe  = 8'd0;

    wire _unused = &{ena, uio_in, ui_in[7:5], 1'b0};
endmodule
