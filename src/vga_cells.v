// 640x480 at 60 Hz VGA timing from a 25 MHz clock, same timing as vga_sync
// in vga_shell.v, but the pixel position is counted in 20-pixel cells:
//   x = xh*20 + xl   (xh 0..39, xl 0..19)
//   y = yh*20 + yl   (yh 0..26, yl 0..19)
// so a game with 20x20 cells needs no dividers, and xl doubles as a
// free-running count modulo 20 (800 pixels per line is 40 cells exactly).
`default_nettype none

module vga_cells (
    input  wire       clk,
    input  wire       rst_n,
    output wire       hsync,    // active low
    output wire       vsync,    // active low
    output wire       active,   // high inside the 640x480 picture
    output wire       frame,    // one clock pulse per picture, at the start of the blanking
    output reg  [5:0] xh,
    output reg  [4:0] xl,
    output reg  [4:0] yh,
    output reg  [4:0] yl
);
    wire xl_end   = (xl == 5'd19);
    wire line_end = xl_end && (xh == 6'd39);

    always @(posedge clk) begin
        if (!rst_n) begin
            xh <= 6'd0; xl <= 5'd0;
            yh <= 5'd0; yl <= 5'd0;
        end else begin
            xl <= xl_end ? 5'd0 : xl + 5'd1;
            if (xl_end) xh <= (xh == 6'd39) ? 6'd0 : xh + 6'd1;
            if (line_end) begin
                if (yh == 5'd26 && yl == 5'd4) begin    // line 524 -> 0
                    yh <= 5'd0; yl <= 5'd0;
                end else if (yl == 5'd19) begin
                    yh <= yh + 5'd1; yl <= 5'd0;
                end else
                    yl <= yl + 5'd1;
            end
        end
    end

    assign active = (xh < 6'd32) && (yh < 5'd24);                        // x < 640, y < 480
    assign hsync  = ~((xh == 6'd32 && xl >= 5'd16) ||                     // x 656..751
                      (xh >= 6'd33 && xh <= 6'd36) ||
                      (xh == 6'd37 && xl < 5'd12));
    assign vsync  = ~(yh == 5'd24 && (yl == 5'd10 || yl == 5'd11));       // y 490..491
    assign frame  = (xh == 6'd32) && (xl == 5'd0) && (yh == 5'd24) && (yl == 5'd0);
endmodule
