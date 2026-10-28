# SPDX-FileCopyrightText: 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


# ============================================================================
# Low-Level Bus Helpers (uio_in = {unused, write_raw, read_tag, bank, addr[3:0]})
# ============================================================================
async def write_byte(dut, addr: int, data: int):
    """Write a single byte across the 2-FF synchronized write strobe."""
    dut.ui_in.value = data & 0xFF
    dut.uio_in.value = (1 << 6) | (addr & 0x3F)  # write_raw = 1
    await ClockCycles(dut.clk, 3)                # Hold across 2-FF synchronizer
    dut.uio_in.value = addr & 0x3F               # write_raw = 0
    await ClockCycles(dut.clk, 2)                # Flush 2-FF synchronizer low


async def read_byte(dut, addr: int) -> int:
    """Read a single byte from the combinational read mux."""
    dut.uio_in.value = addr & 0x3F               # write_raw = 0, addr[5]=read_tag, addr[4]=bank
    await ClockCycles(dut.clk, 1)
    val = int(dut.uo_out.value)
    dut.uio_in.value = 0x00
    return val


async def wait_status_bit(dut, mask: int, timeout_cycles: int = 200):
    """Poll Status Register (0x10) until (status & mask) != 0."""
    for _ in range(timeout_cycles):
        status = await read_byte(dut, 0x10)
        if (status & mask) != 0:
            return status
    raise AssertionError(f"Timeout waiting for status mask 0x{mask:02x}")


async def write_buffer_128(dut, block_128: int):
    """Write 16 bytes (MSB at 0x00, LSB at 0x0F) into the shared buffer."""
    for i in range(16):
        byte_val = (block_128 >> (120 - 8 * i)) & 0xFF
        await write_byte(dut, i, byte_val)


async def read_buffer_128(dut) -> int:
    """Read 16 bytes (MSB at 0x00, LSB at 0x0F) from the shared buffer."""
    res = 0
    for i in range(16):
        b = await read_byte(dut, i)
        res = (res << 8) | b
    return res


async def read_tag_128(dut) -> int:
    """Read 16 bytes of Authentication Tag from 0x20..0x2F (read_tag = 1)."""
    res = 0
    for i in range(16):
        b = await read_byte(dut, 0x20 + i)
        res = (res << 8) | b
    return res


# ============================================================================
# High-Level Ascon-128 Transaction Helpers
# ============================================================================
async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def init_nonce_and_key(dut, nonce: int, key: int):
    # 1. Wait for ready_for_nonce (bit 0)
    await wait_status_bit(dut, 0x01)
    await write_buffer_128(dut, nonce)
    await write_byte(dut, 0x10, 0x01)  # load = 1

    # 2. Wait for ready_for_key (bit 1)
    await wait_status_bit(dut, 0x02)
    await write_buffer_128(dut, key)
    await write_byte(dut, 0x10, 0x01)  # load = 1 (starts 12-round init)


async def skip_ad_phase(dut):
    await wait_status_bit(dut, 0x04)   # Wait for ready_for_ad (bit 2)
    await write_byte(dut, 0x10, 0x40)  # ad_empty = 1 (bit 6)


async def send_ad_block(dut, ad_blk: int, length: int, is_last: bool):
    await wait_status_bit(dut, 0x04)   # Wait for ready_for_ad (bit 2)
    await write_buffer_128(dut, ad_blk)
    ctrl = ((length & 0xF) << 2) | ((1 if is_last else 0) << 1) | 0x01
    await write_byte(dut, 0x10, ctrl)


async def send_pt_and_read_ct(dut, pt_blk: int, length: int, is_last: bool) -> int:
    await wait_status_bit(dut, 0x08)   # Wait for ready_for_pt (bit 3)
    await write_buffer_128(dut, pt_blk)
    ctrl = ((length & 0xF) << 2) | ((1 if is_last else 0) << 1) | 0x01
    await write_byte(dut, 0x10, ctrl)

    await wait_status_bit(dut, 0x10)   # Wait for ct_ready (bit 4)
    return await read_buffer_128(dut)


async def finish_and_read_tag(dut) -> int:
    await wait_status_bit(dut, 0x20)   # Wait for finish_reg (bit 5)
    return await read_tag_128(dut)


# ============================================================================
# Cocotb Tests
# ============================================================================
@cocotb.test()
async def test_ascon_aead_suite(dut):
    """Comprehensive end-to-end Ascon-128 AEAD verification suite."""
    dut._log.info("Starting Ascon-128 AEAD Cocotb Verification Suite")

    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Check bidirectional pin direction & output ties
    assert int(dut.uio_oe.value) == 0x00, f"Expected uio_oe == 0x00, got 0x{int(dut.uio_oe.value):02x}"
    assert int(dut.uio_out.value) == 0x00, f"Expected uio_out == 0x00, got 0x{int(dut.uio_out.value):02x}"

    # ------------------------------------------------------------------------
    # Test 1: 1-Block AD (8B) + 1-Block PT (5B)
    # ------------------------------------------------------------------------
    dut._log.info("Running Test 1: 1-Block AD (8B) + 1-Block PT (5B)...")
    await init_nonce_and_key(
        dut,
        nonce=0x000102030405060708090A0B0C0D0E0F,
        key=0x000102030405060708090A0B0C0D0E0F,
    )
    await send_ad_block(dut, 0xA0A1A2A3A4A5A6A7A8A9AAABACADAEAF, length=8, is_last=True)
    ct0 = await send_pt_and_read_ct(dut, 0xB0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF, length=5, is_last=True)
    tag = await finish_and_read_tag(dut)

    assert ct0 == 0x91F5F635690000000000000000000000, f"Test 1 CT mismatch: {ct0:032x}"
    assert tag == 0x09BC056F68406A5A3EF6518EB967E09C, f"Test 1 Tag mismatch: {tag:032x}"
    dut._log.info(f"  [PASS] Test 1 CT={ct0:032x} TAG={tag:032x}")

    # ------------------------------------------------------------------------
    # Test 2: Empty AD (ad_empty=1) + 1-Block PT (10B)
    # ------------------------------------------------------------------------
    dut._log.info("Running Test 2: Empty AD (ad_empty=1) + 1-Block PT (10B)...")
    await init_nonce_and_key(
        dut,
        nonce=0x101112131415161718191A1B1C1D1E1F,
        key=0x000102030405060708090A0B0C0D0E0F,
    )
    await skip_ad_phase(dut)
    ct0 = await send_pt_and_read_ct(dut, 0x0102030405060708090A0B0C0D0E0F10, length=10, is_last=True)
    tag = await finish_and_read_tag(dut)

    assert ct0 == 0x42D9BD80DBA205D67BD6000000000000, f"Test 2 CT mismatch: {ct0:032x}"
    assert tag == 0x62EA5EFBB79A0497E92E281FF81C666C, f"Test 2 Tag mismatch: {tag:032x}"
    dut._log.info(f"  [PASS] Test 2 CT={ct0:032x} TAG={tag:032x}")

    # ------------------------------------------------------------------------
    # Test 3: Empty AD (ad_empty=1) + Empty PT (0B)
    # ------------------------------------------------------------------------
    dut._log.info("Running Test 3: Empty AD (ad_empty=1) + Empty PT (0B)...")
    await init_nonce_and_key(
        dut,
        nonce=0x0123456789ABCDEF0123456789ABCDEF,
        key=0xFEDCBA9876543210FEDCBA9876543210,
    )
    await skip_ad_phase(dut)
    ct0 = await send_pt_and_read_ct(dut, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, length=0, is_last=True)
    tag = await finish_and_read_tag(dut)

    assert ct0 == 0x00000000000000000000000000000000, f"Test 3 CT mismatch: {ct0:032x}"
    assert tag == 0xE8608B81843DEAEE18E666CAC5BD3586, f"Test 3 Tag mismatch: {tag:032x}"
    dut._log.info(f"  [PASS] Test 3 CT={ct0:032x} TAG={tag:032x}")

    # ------------------------------------------------------------------------
    # Test 4: 2-Block AD (16B + 7B) + 1-Block PT (9B)
    # ------------------------------------------------------------------------
    dut._log.info("Running Test 4: 2-Block AD (16B + 7B) + 1-Block PT (9B)...")
    await init_nonce_and_key(
        dut,
        nonce=0x000102030405060708090A0B0C0D0E0F,
        key=0x000102030405060708090A0B0C0D0E0F,
    )
    await send_ad_block(dut, 0xA0A1A2A3A4A5A6A7A8A9AAABACADAEAF, length=0, is_last=False)
    await send_ad_block(dut, 0xB0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF, length=7, is_last=True)
    ct0 = await send_pt_and_read_ct(dut, 0xC0C1C2C3C4C5C6C7C8C9CACBCCCDCECF, length=9, is_last=True)
    tag = await finish_and_read_tag(dut)

    assert ct0 == 0xD3F778E20424FAE34900000000000000, f"Test 4 CT mismatch: {ct0:032x}"
    assert tag == 0xA51C03A61A87311504C21BD51AE56FB3, f"Test 4 Tag mismatch: {tag:032x}"
    dut._log.info(f"  [PASS] Test 4 CT={ct0:032x} TAG={tag:032x}")

    # ------------------------------------------------------------------------
    # Test 5: 1-Block AD (4B) + 2-Block PT (16B + 11B)
    # ------------------------------------------------------------------------
    dut._log.info("Running Test 5: 1-Block AD (4B) + 2-Block PT (16B + 11B)...")
    await init_nonce_and_key(
        dut,
        nonce=0x1234567890ABCDEF1234567890ABCDEF,
        key=0x5555555555555555AAAAAAAAAAAAAAAA,
    )
    await send_ad_block(dut, 0xDEADBEEF000000000000000000000000, length=4, is_last=True)
    ct0 = await send_pt_and_read_ct(dut, 0x00112233445566778899AABBCCDDEEFF, length=0, is_last=False)
    ct1 = await send_pt_and_read_ct(dut, 0xFFEEDDCCBBAA99887766554433221100, length=11, is_last=True)
    tag = await finish_and_read_tag(dut)

    assert ct0 == 0x276A0820947F0E7A4D86A3E04DDB305A, f"Test 5 CT[0] mismatch: {ct0:032x}"
    assert ct1 == 0x6E56EB285603AC66CD08B60000000000, f"Test 5 CT[1] mismatch: {ct1:032x}"
    assert tag == 0x52FEE1E15618DBF23E3BF6515B952038, f"Test 5 Tag mismatch: {tag:032x}"
    dut._log.info(f"  [PASS] Test 5 CT0={ct0:032x} CT1={ct1:032x} TAG={tag:032x}")

    dut._log.info("All Ascon-128 Cocotb tests PASSED!")
