<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This project implements a hardware accelerator for the **Ascon-128** Authenticated Encryption with Associated Data (AEAD) cipher, standardized by NIST in **SP 800-232** for lightweight cryptography.

### Core Architecture

Ascon-128 operates on a 320-bit internal state divided into five 64-bit words (`S0` through `S4`), where `S0` and `S1` form the 128-bit outer rate (data absorption/squeezing) and `S2`, `S3`, `S4` form the 192-bit inner capacity.

The hardware is partitioned into three modules:
1. **`ascon_round.v`**: A pure combinational single-round permutation engine that executes one full 320-bit Ascon round per clock cycle:
   - **Constant Addition Layer (`p_C`)**: XORs an 8-bit round constant (`{~i, i}`) into `S2[7:0]`.
   - **Substitution Layer (`p_S`)**: Applies 64 parallel 5-bit S-boxes across all 64 bit-columns of `S0..S4` using boolean bit-sliced equations.
   - **Linear Diffusion Layer (`p_L`)**: Applies the specification's 64-bit circular right rotations (`ROTR`) to each word `S0..S4`.
2. **`ascon_encryption.v`**: An 8-state Finite State Machine (FSM) controlling the four AEAD phases:
   - **Initialization (`I_NONCE` -> `I_KEY` -> `I_PERMUTATE`)**: Loads the 128-bit Nonce and 64-bit `IV` (`0x00001000808c0001`), loads and saves the 128-bit Key, runs 12 permutation rounds (`p12`), and XORs the Key into capacity words `S3, S4`.
   - **Associated Data (`AD_LOAD` -> `AD_PERMUTATE`)**: Absorbs arbitrary-length Associated Data (AD) in 128-bit blocks with 8 permutation rounds (`p8`) per block, or skips directly to Plaintext when `ad_empty = 1`. Automatically applies `0x80` byte padding on the final block and flips the domain-separation bit `S4[0]`.
   - **Plaintext Encryption (`PT_LOAD` -> `PT_PERMUTATE`)**: Absorbs 128-bit Plaintext (PT) blocks, outputs truncated Ciphertext (CT) blocks, and runs 8 permutation rounds (`p8`) for intermediate blocks.
   - **Finalization (`F_PERMUTATE`)**: On the final Plaintext block (`last = 1`), pads the Plaintext, XORs the 128-bit Key into `S2, S3`, runs 12 permutation rounds (`p12`), and XORs the Key into `S3, S4` to produce the 128-bit Authentication Tag (`T`).
3. **`tt_um_ascon.v`**: The Tiny Tapeout 24-pin memory-mapped bus wrapper containing a 2-flip-flop write-strobe synchronizer (`write_pulse`), a shared 128-bit data buffer (`buffer`), sticky event flags (`ct_ready`, `finish_reg`), and a combinational read multiplexer.

### Pinout and Bus Mapping

| Pin Group | Signal Name | Direction | Description |
| :--- | :--- | :---: | :--- |
| `ui_in[7:0]` | `data_in[7:0]` | Input | 8-bit Write Data Bus from host |
| `uo_out[7:0]` | `data_out[7:0]` | Output | 8-bit Read Data Bus to host |
| `uio_in[3:0]` | `byte_addr[3:0]` | Input | Byte offset (`0x0` = MSB `[127:120]` .. `0xF` = LSB `[7:0]`) |
| `uio_in[4]` | `bank` | Input | Register bank select (`0` = Shared Buffer, `1` = Control/Status) |
| `uio_in[5]` | `read_tag` | Input | Tag read select (`1` = Read 128-bit Tag `T[byte_addr]`) |
| `uio_in[6]` | `write_raw` | Input | Asynchronous/synchronous write strobe (rising-edge triggered) |
| `uio_in[7]` | `unused` | Input | Unused (tied off) |

### Register & Memory Map

Combining `uio_in[5:0]` as `{read_tag, bank, byte_addr[3:0]}` forms a 6-bit address space:

| Address (`uio_in[5:0]`) | `read_tag` | `bank` | `byte_addr` | Access | Register / Description |
| :---: | :---: | :---: | :---: | :---: | :--- |
| `0x00` - `0x0F` | `0` | `0` | `0x0` - `0xF` | R / W | **128-bit Shared Data Buffer (`buffer`)**<br>- **Write**: Load Nonce, Key, AD, or Plaintext (`0x00` = MSB, `0x0F` = LSB)<br>- **Read**: Read captured 128-bit Ciphertext (`CT`) |
| `0x10` | `0` | `1` | `0x0` | Write | **Control Register**<br>- `bit[0]`: `load` (1-cycle trigger pulse)<br>- `bit[1]`: `last` (`1` = final block of AD or PT)<br>- `bit[5:2]`: `data_length` (`0..15` valid bytes in final partial block)<br>- `bit[6]`: `ad_empty` (`1` = skip AD phase when in `AD_LOAD`)<br>- `bit[7]`: unused |
| `0x10` | `0` | `1` | `0x0` | Read | **Status Register**<br>- `bit[0]`: `ready_for_nonce`<br>- `bit[1]`: `ready_for_key`<br>- `bit[2]`: `ready_for_ad`<br>- `bit[3]`: `ready_for_pt`<br>- `bit[4]`: `ct_ready` (Ciphertext block latched in `buffer`)<br>- `bit[5]`: `finish_reg` (Encryption complete, Tag valid)<br>- `bit[7:6]`: `2'b00` |
| `0x20` - `0x2F` | `1` | `X` | `0x0` - `0xF` | Read-Only | **128-bit Authentication Tag (`T`)**<br>Reads `state[127:0]` directly (`0x20` = MSB, `0x2F` = LSB) |

## How to test

### Step-by-Step Host Protocol

To perform an authenticated encryption transaction from the host microcontroller (RP2040) or FPGA:

1. **Reset**: Hold `rst_n = 0` for at least 4 clock cycles, then release `rst_n = 1`.
2. **Load Nonce**:
   - Poll Status (`0x10`) until `ready_for_nonce` (`bit[0] == 1`).
   - Write the 16-byte Nonce into `0x00` (MSB) through `0x0F` (LSB).
   - Write `0x01` (`load = 1`) to Control (`0x10`).
3. **Load Key**:
   - Poll Status (`0x10`) until `ready_for_key` (`bit[1] == 1`).
   - Write the 16-byte Key into `0x00` through `0x0F`.
   - Write `0x01` (`load = 1`) to Control (`0x10`). The core immediately runs the 12-round initialization permutation.
4. **Absorb Associated Data (AD)**:
   - Poll Status (`0x10`) until `ready_for_ad` (`bit[2] == 1`).
   - **If there is no AD**: Write `0x40` (`ad_empty = 1`) to Control (`0x10`).
   - **If there is AD**: For each 16-byte block, write the bytes to `0x00..0x0F` and write `{2'b00, data_length[3:0], last, 1'b1}` to Control (`0x10`), waiting for `ready_for_ad == 1` between blocks.
5. **Encrypt Plaintext (PT) & Read Ciphertext (CT)**:
   - For each PT block, poll Status (`0x10`) until `ready_for_pt` (`bit[3] == 1`).
   - Write the PT block to `0x00..0x0F` and write `{2'b00, data_length[3:0], last, 1'b1}` to Control (`0x10`).
   - Poll Status (`0x10`) until `ct_ready` (`bit[4] == 1`), then read the Ciphertext bytes from `0x00..0x0F`.
6. **Read Authentication Tag (`T`)**:
   - After the final PT block (`last = 1`), poll Status (`0x10`) until `finish_reg` (`bit[5] == 1`).
   - Read the 16-byte Authentication Tag from `0x20` (`read_tag = 1, byte_addr = 0`) through `0x2F` (`read_tag = 1, byte_addr = 15`).

### Golden Test Vector

- **Key (16B)**: `000102030405060708090a0b0c0d0e0f`
- **Nonce (16B)**: `000102030405060708090a0b0c0d0e0f`
- **Associated Data (8B, `last = 1, data_length = 8`)**: `a0a1a2a3a4a5a6a7`
- **Plaintext (5B, `last = 1, data_length = 5`)**: `b0b1b2b3b4`
- **Expected Ciphertext (`0x00..0x0F`)**: `91f5f635690000000000000000000000` (first 5 bytes `91f5f63569`)
- **Expected Tag (`0x20..0x2F`)**: `09bc056f68406a5a3ef6518eb967e09c`

### Running Simulation

Run the Cocotb verification suite locally using Icarus Verilog:
```sh
cd test
make -B
```

## External hardware

No external hardware is required. The chip is controlled directly by the on-board RP2040 microcontroller on the Tiny Tapeout demo board, or can be driven by an external FPGA (such as a Digilent Basys 3) or microcontroller over the PMOD headers.
