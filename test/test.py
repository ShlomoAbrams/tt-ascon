# SPDX-FileCopyrightText: 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_ascon(dut):
    dut._log.info(Starting Ascon-128 AEAD Cocotb test)

    # Set the clock period to 20 ns (50 MHz)
    clock = Clock(dut.clk, 20, unit=ns)
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info(Applying reset...)
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # Poll status register: bank=1, addr=0 -> uio_in = 0x10
    dut._log.info(Reading status register at 0x10...)
    dut.uio_in.value = 0x10
    await ClockCycles(dut.clk, 2)

    status = int(dut.uo_out.value)
    dut._log.info(fStatus register value: 0x{status:02x})

    # bit 0 should be ready_for_nonce = 1
    assert (status & 0x01) == 0x01, fExpected ready_for_nonce (bit 0) to be 1, got 0x{status:02x}
    dut._log.info(Ascon test passed: ready_for_nonce confirmed high!)
