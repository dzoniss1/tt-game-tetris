# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, Timer
from cocotb.utils import get_sim_time

PERIOD_NS = 40            # 25 MHz pixel clock
LINE, FRAME = 800, 800 * 525

BLACK, WHITE, GREY = 0b000000, 0b111111, 0b101010


def rgb6(uo):
    """TinyVGA PMOD pins -> {R1,R0,G1,G0,B1,B0}."""
    bit = lambda i: (uo >> i) & 1
    return (bit(0) << 5) | (bit(4) << 4) | (bit(1) << 3) | (bit(5) << 2) | (bit(2) << 1) | bit(6)


class Beam:
    """Samples the outputs while pixel (x, y) of a given frame is drawn,
    counting clocks from the release of reset."""

    def __init__(self, dut, t0):
        self.dut, self.t0 = dut, t0

    async def at(self, frame, x, y):
        n = frame * FRAME + y * LINE + x
        t = self.t0 + n * PERIOD_NS + PERIOD_NS // 4
        now = get_sim_time(unit="ns")
        assert t > now, "beam position already passed"
        await Timer(t - now, unit="ns")
        await ReadOnly()
        return int(self.dut.uo_out.value)

    async def pixel(self, frame, x, y):
        return rgb6(await self.at(frame, x, y))


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    clock = Clock(dut.clk, PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    beam = Beam(dut, get_sim_time(unit="ns"))

    await ClockCycles(dut.clk, 100)

    # Nothing should be stuck at X or Z once the design has been reset and clocked.
    assert dut.uo_out.value.is_resolvable, "uo_out has X or Z bits"
    assert dut.uio_out.value.is_resolvable, "uio_out has X or Z bits"
    assert dut.uio_oe.value.is_resolvable, "uio_oe has X or Z bits"

    # VGA 640x480 timing: hsync low for x 656..751, vsync low for y 490..491.
    for x, level in ((655, 1), (656, 0), (751, 0), (752, 1)):
        assert (await beam.at(0, x, 10)) >> 7 & 1 == level, f"hsync wrong at x={x}"
    assert await beam.pixel(0, 700, 100) == BLACK, "colour outside the picture"
    for y, level in ((489, 1), (490, 0), (491, 0), (492, 1)):
        assert (await beam.at(0, 100, y)) >> 3 & 1 == level, f"vsync wrong at y={y}"

    # Title screen (frame 1). Checks go in beam order.
    assert await beam.pixel(1, 223, 21) == WHITE, "score label S missing"
    assert await beam.pixel(1, 310, 70) == BLACK, "piece shown on the title screen"
    assert await beam.pixel(1, 217, 100) == GREY, "board frame missing"
    assert await beam.pixel(1, 230, 100) == BLACK, "board not empty"
    assert await beam.pixel(1, 281, 221) == WHITE, "PRESS text missing"

    # Press rotate: sampled at the end of frame 1, starts a game.
    await Timer(1, unit="ns")             # leave the read-only phase
    dut.ui_in.value = 0b0100
    await beam.at(2, 0, 10)
    await Timer(1, unit="ns")
    dut.ui_in.value = 0

    # Frame 2: title gone, a new piece at the top. Every tetromino covers
    # board cell (column 4, row 1) when it spawns.
    assert await beam.pixel(2, 310, 70) != BLACK, "no piece after start"
    assert await beam.pixel(2, 217, 100) == GREY, "board frame missing"
    assert await beam.pixel(2, 281, 221) == BLACK, "title still shown after start"

    dut._log.info("Pass")
