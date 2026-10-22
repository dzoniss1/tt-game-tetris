## How it works

Tetris on a 640x480 VGA screen, in a 1x2 tile.

The 10x20 board is drawn at (220,40) in 20x20-pixel cells, with a grey frame and black grid lines. Every piece has its own colour and keeps it after it locks, until game over. Above the board, `S###` is the score (one point per piece locked) and `H###` is the best score since reset. A title screen shows "PRESS ANY BUTTON TO START". When a new piece cannot be placed, the board turns grey and "GAME OVER" blinks.

Pieces are picked at random from the 7 tetrominoes. Rotation is clockwise. If a rotation is blocked, it tries one column to the left, then one to the right. Each input acts once per event and never repeats while held: left, right and rotate move or turn the piece once, and down moves it one row. With `ui[4]` = 0 an event is every flip of the input (DIP switches, VGA Playground keys 0-3); with `ui[4]` = 1 it is only a press (push buttons). The piece falls one row every 10 frames at the start, and one frame faster for every 10 cleared lines, down to every 2 frames.

How it fits in one tile:

- The VGA position is counted in 20-pixel cells (`vga_cells.v`), so finding the board cell of a pixel needs no division. The sync timing is the same as the standard 640x480 shell.
- The board is a shift register of 20 rows (3 bits per cell: empty or piece type) that turns by one row every clock. A full turn takes 20 clocks. The row at its head is always the VGA x position modulo 20, so no address counter, read multiplexer or write enables are needed.
- During vertical blanking the game logic works on the head row only:
  - collision tests and locking handle one cell at a time as its row passes;
  - clearing a line copies each row from the one above it (the next 10 bits of the register), starting at the lowest full row.
- Piece shapes come from a small ROM indexed by type and rotation. The score is kept in BCD, so there are no dividers.

## How to test

Connect a TinyVGA PMOD and a VGA monitor, and run the clock at 25.175 MHz (25 MHz also works). Connect the inputs (active high) to `ui[0]` left, `ui[1]` right, `ui[2]` rotate and `ui[3]` down. Set `ui[4]` to 0 for switches or 1 for push buttons. Flip or press any input to start a game. In the VGA Playground, keys 0-3 control the game.

## External hardware

TinyVGA PMOD, a VGA monitor, and four switches or push buttons.
