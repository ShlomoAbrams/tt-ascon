`default_nettype none

/**
 * ============================================================================
 * Tiny Tapeout Top-Level Module: tt_um_ascon
 * ============================================================================
 * 
 * ============================================================================
 * PIN & MEMORY MAP (uio_in = {unused, write_raw, read_tag, bank, byte_addr[3:0]})
 * ============================================================================
 * 
 *  read_tag | bank | byte_addr | Access | Description
 * ----------+------+-----------+--------+-------------------------------------
 *     0     |  0   | 0x0 - 0xF | R / W  | 128-bit Shared Buffer (16 Bytes)
 *           |      |           |        |   WRITE: Nonce, Key, AD, PT
 *           |      |           |        |   READ : Ciphertext (CT)
 *           |      |           |        |   Byte 0  (byte_addr=0)  = MSB [127:120]
 *           |      |           |        |   Byte 15 (byte_addr=15) = LSB [7:0]
 * ----------+------+-----------+--------+-------------------------------------
 *     0     |  1   | 0x0       | R / W  | Control & Status Register (0x10)
 *           |      |           |        |
 *           |      |           | WRITE  | Core Control:
 *           |      |           |        |   bit[0]   : load (1-cycle pulse)
 *           |      |           |        |   bit[1]   : last (1 = last block of AD/PT)
 *           |      |           |        |   bit[5:2] : data_length (0..15 bytes)
 *           |      |           |        |   bit[6]   : ad_empty (1 = skip AD phase)
 *           |      |           |        |   bit[7]   : unused
 *           |      |           |        |
 *           |      |           | READ   | Core Status:
 *           |      |           |        |   bit[0]   : ready_for_nonce
 *           |      |           |        |   bit[1]   : ready_for_key
 *           |      |           |        |   bit[2]   : ready_for_ad
 *           |      |           |        |   bit[3]   : ready_for_pt
 *           |      |           |        |   bit[4]   : ct_ready (CT in buffer)
 *           |      |           |        |   bit[5]   : finish_reg (Tag ready!)
 *           |      |           |        |   bit[7:6] : 2'b00
 * ----------+------+-----------+--------+-------------------------------------
 *     1     |  X   | 0x0 - 0xF | R-only | 128-bit Authentication Tag (T)
 *           |      |           |        |   Byte 0  (byte_addr=0)  = MSB [127:120]
 *           |      |           |        |   Byte 15 (byte_addr=15) = LSB [7:0]
 * ============================================================================
 */

module tt_um_ascon (
    input  wire [7:0] ui_in,    // Dedicated inputs  : Write Data Bus [7:0]
    output wire [7:0] uo_out,   // Dedicated outputs : Read Data Bus  [7:0]
    input  wire [7:0] uio_in,   // Bidirectional in  : {unused, write_raw, read_tag, bank, byte_addr[3:0]}
    output wire [7:0] uio_out,  // Bidirectional out : Unused (tied to 0)
    output wire [7:0] uio_oe,   // Pin direction ctrl: Unused (all inputs)
    input  wire       ena,      // Tiny Tapeout enable (always 1)
    input  wire       clk,      // System clock
    input  wire       rst_n     // Active-low asynchronous reset
);

    // ========================================================================
    // 1. Pin Configuration & Unpacking
    // ========================================================================
    // Configure bidirectional pins as dedicated inputs
    assign uio_oe  = 8'b00000000;
    assign uio_out = 8'b00000000;

    // Unpack IO pins
    wire [3:0] byte_addr    = uio_in[3:0];  // Byte offset (0..15)
    wire bank               = uio_in[4];    // Memory bank selection (0: Buffer, 1: Control)
    wire read_tag           = uio_in[5];    // Tag read strobe from host
    wire write_raw          = uio_in[6];    // Raw write strobe from host

    // Output assignment
    reg [7:0] rdata;
    assign uo_out = rdata;

    wire _unused = &{ena, 1'b0, uio_in[7]}; // Avoid unused signal warnings

    // ========================================================================
    // 2. Host Write Synchronizer (Input Stage)
    // ========================================================================
    // Double-flop synchronizer + edge detector to generate 1-cycle write pulse
    reg w_sync1, w_sync2, w_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_sync1 <= 1'b0;
            w_sync2 <= 1'b0;
            w_prev  <= 1'b0;
        end else begin
            w_sync1 <= write_raw;
            w_sync2 <= w_sync1;
            w_prev  <= w_sync2;
        end
    end
    wire write_pulse = (w_sync2 == 1'b1) && (w_prev == 1'b0);

    // ========================================================================
    // 3. Registers & Internal Wires
    // ========================================================================
    
    // Shared 128-bit data buffer (for associated data, plaintext and ciphertext)
    reg [127:0] buffer;

    // Host-controlled registers to core
    reg       load;
    reg       last;
    reg [3:0] data_length;
    reg       ad_empty;

    // Sticky status flags for host polling
    reg ct_ready;
    reg finish_reg;

    // Output wires from encryption core
    wire [127:0] ct;
    wire [127:0] t;
    wire         finish;
    wire         ct_valid;
    wire         ready_for_nonce;
    wire         ready_for_key;
    wire         ready_for_ad;
    wire         ready_for_pt;

    // ========================================================================
    // 4. Ascon Encryption Core Instantiation
    // ========================================================================
    encryption u_encryption (
        .clk            (clk),
        .reset_n        (rst_n),
        .data_in        (buffer),
        .load           (load),
        .last           (last),
        .data_length    (data_length),
        .ad_empty       (ad_empty),
        .ct             (ct),
        .t              (t),
        .finish         (finish),
        .ct_valid       (ct_valid),
        .ready_for_nonce(ready_for_nonce),
        .ready_for_key  (ready_for_key),
        .ready_for_ad   (ready_for_ad),
        .ready_for_pt   (ready_for_pt)
    );

    // ========================================================================
    // 5. Synchronous Updates (Host Writes & Core Events)
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer      <= 128'b0;
            load        <= 1'b0;
            last        <= 1'b0;
            data_length <= 4'd0;
            ad_empty    <= 1'b0;
            ct_ready    <= 1'b0;
            finish_reg  <= 1'b0;
        end else begin
            // ----------------------------------------------------------------
            // Core Hardware Events (Highest priority for capturing core results)
            // ----------------------------------------------------------------
            if (ct_valid) begin
                buffer   <= ct;       // Capture ciphertext block into buffer
                ct_ready <= 1'b1;     // Notify host that ciphertext is ready
            end

            if (finish) begin
                finish_reg <= 1'b1;   // Latch finished flag (Tag is ready)
            end

            // ----------------------------------------------------------------
            // Host Write Processing
            // ----------------------------------------------------------------
            if (write_pulse && !read_tag) begin
                case (bank)
                    1'b0: begin
                        // 0x00 - 0x0F: Write individual byte into 128-bit buffer
                        buffer[127 - byte_addr*8 -: 8] <= ui_in;
                    end

                    1'b1: begin
                        if (byte_addr == 4'h0) begin // 0x10: Write control flags into Ascon encryption core
                            load        <= ui_in[0];
                            last        <= ui_in[1];
                            data_length <= ui_in[5:2];
                            ad_empty    <= ui_in[6];

                            // Auto-clear flags when starting corresponding operations
                            if (ui_in[0] && ready_for_nonce) begin
                                finish_reg <= 1'b0; // Starting new packet
                            end
                            if (ui_in[0] && ready_for_pt) begin
                                ct_ready   <= 1'b0; // Loading new plaintext block
                            end
                        end
                    end
                endcase
            end else begin
                // Clear single-cycle trigger pulses when no write occurs
                load     <= 1'b0;
                ad_empty <= 1'b0;
            end
        end
    end

    // ========================================================================
    // 6. Host Read Multiplexer (Combinational Output Stage)
    // ========================================================================
    wire [127:0] ct_or_tag      = read_tag ? t : buffer;
    wire [7:0]   ct_or_tag_byte = ct_or_tag[127 - byte_addr*8 -: 8];

    always @(*) begin
        case ({read_tag, bank})
            2'b00: begin
                // read_tag = 0, bank = 0 (0x00 - 0x0F): Read Ciphertext from buffer
                rdata = ct_or_tag_byte;
            end

            2'b01: begin
                // read_tag = 0, bank = 1 (0x10): Read status register
                if (byte_addr == 4'h0) begin
                    rdata = {2'b00, finish_reg, ct_ready, ready_for_pt, ready_for_ad, ready_for_key, ready_for_nonce};
                end else begin
                    rdata = 8'h00;
                end
            end

            2'b10, 2'b11: begin
                // read_tag = 1: Read 128-bit Authentication Tag
                rdata = ct_or_tag_byte;
            end

            default: begin
                rdata = 8'h00;
            end
        endcase
    end

endmodule