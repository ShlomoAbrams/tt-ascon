// ascon encryption module:
module encryption(
    input   wire           clk,             // clock
    input   wire           reset_n,         // reset
    input   wire [127:0]   data_in,         // single 128-bit input bus (Nonce, Key, AD, PT)
    input   wire           load,            // load input data
    input   wire           last,            // last data block flag
    input   wire [3:0]     data_length,     // partial block length (0..15 bytes)
    input   wire           ad_empty,        // no associated data flag
    output  wire [127:0]   ct,              // cipher text
    output  wire [127:0]   t,               // tag
    output  wire           finish,          // encryption finished
    output  wire           ct_valid,        // valid ct output
    output  wire           ready_for_nonce, // waiting for Nonce
    output  wire           ready_for_key,   // waiting for Key
    output  wire           ready_for_ad,    // waiting for Associated Data
    output  wire           ready_for_pt     // waiting for Plaintext
);

    // registers:
    reg [127:0] k; 
    reg [319:0] state;
    reg [3:0]   i;       // round counter
    reg         ad_last; // flag that no more associated data is coming 

    // wires:
    wire [319:0] state_o;  // permutation output state
    wire [127:0] ad_or_pt; // ad or pt with padding if last block
    wire [7:0]   round_c;  // round constants


    // round constants:
    assign round_c = {~i,i}; // 12 round constants: 0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5, 0x96, 0x87, 0x78, 0x69, 0x5a, 0x4b
    
    // pad ad or pt if last block
    assign ad_or_pt = (last) ? pad(data_in, data_length) : data_in;

    // permutation module: runs 12/8 permutations
    ascon_round u_ascon_round(
        .round_c (round_c),
        .state_i (state),
        .state_o (state_o)
    );

    // parameter:
    localparam IV = 64'h00001000808c0001; 

    // finite state machine:
    localparam I_NONCE      = 3'h0; // 1. Load Nonce
    localparam I_KEY        = 3'h1; // 2. Load Key
    localparam I_PERMUTATE  = 3'h2; // 3. 12 rounds permutation + add key
    localparam AD_LOAD      = 3'h3; // 4. Load Associated Data
    localparam AD_PERMUTATE = 3'h4; // 5. 8 rounds AD permutation + invert state's LSB
    localparam PT_LOAD      = 3'h5; // 6. Load Plaintext
    localparam PT_PERMUTATE = 3'h6; // 7. 8 rounds PT permutation
    localparam F_PERMUTATE  = 3'h7; // 8. 12 rounds final permutation + ouput tag

    reg [2:0] fsm;

    /////////////////////
    // encryption core //
    /////////////////////

    always @(posedge clk or negedge reset_n) begin 
        if (!reset_n) begin
            state   <= 320'b0;
            k       <= 128'b0;
            ad_last <= 1'b0;
            i       <= 4'b0;
            fsm     <= I_NONCE;         
        end
        else begin
            case (fsm)
                /////////////////////////////
                // a. initialization phase //
                /////////////////////////////

                // 1. Load Nonce into state[127:0] and pre-set IV
                I_NONCE: begin
                    if (load) begin
                        state[127:0]   <= data_in;  // Nonce placed at S3, S4
                        state[319:256] <= IV;       // IV placed at S0
                        fsm            <= I_KEY;    // load key
                    end
                end

                // 2. Load Key into state[255:128], save in k, and begin 12 rounds
                I_KEY: begin
                    if (load) begin
                        k              <= data_in;      // Save key for I_FINISH, F_LOAD, and Tag
                        state[255:128] <= data_in;      // Key placed at S1, S2
                        i              <= 4'd0;         // reset counter for permutation *12
                        fsm            <= I_PERMUTATE;  // start permutation *12
                    end
                end

                // 3. Permutate *12
                I_PERMUTATE: begin
                    if (i<11) begin // run permutation *12
                        state <= state_o;  // update state after permutation
                        i <= i+1'b1; // inctement round counter
                    end
                // 4. Add key
                    else begin      // finish permutation xor state with key
                        state <= state_o ^ {192'b0, k};  // update state after permutation with key
                        fsm <= AD_LOAD;
                    end
                end

                //////////////////////////////
                // b. associated data phase //
                //////////////////////////////

                // 1. add associated data
                AD_LOAD: begin
                    if (ad_empty) begin
                        state[0] <= ~state[0]; // invert state's LSB
                        fsm <= PT_LOAD;        // go to plaintext loading phase
                    end
                    else if (load) begin
                        i       <= 4'd4; // reset round counter to 4 for 8 rounds
                        ad_last <= last; // Store ad_last so core remembers during permutation
                        fsm     <= AD_PERMUTATE; 
                        state   <= state ^ {ad_or_pt, 192'b0}; // add ad to state
                    end
                end

                // 2. permutate *8
                AD_PERMUTATE: begin
                    if (i<11) begin // run permutation *8
                        state <= state_o;  // update state after permutation
                        i <= i+1'b1; // inctement round counter
                    end
                    else begin      // finish permutation
                        if (ad_last) begin
                            state <= {state_o[319:1],~state_o[0]}; // invert LSB of state
                            fsm <= PT_LOAD;
                        end
                        else begin
                            state <= state_o;   // update state after permutation
                            fsm <= AD_LOAD;     // middle block
                        end
                    end
                end

                // 3. inverted state's LSB (done in the last block of permutation)

                ////////////////////////
                // c. plaintext phase //
                ////////////////////////

                // 1. add plaintext
                PT_LOAD: begin
                    if (load) begin
                        if (last) begin // last block: pad pt, add key
                            state <= state ^ {ad_or_pt, k, 64'b0}; // add key for finilaization stage
                            i     <= 4'd0;      // reset counter to 0 for finilization stage
                            fsm <= F_PERMUTATE; // go to finalization stage
                        end
                        else begin      // middle block: 16 bytes
                            state   <= state ^ {ad_or_pt, 192'b0};
                            i <= 4'd4; // reset round counter to 4 for 8 rounds
                            fsm <= PT_PERMUTATE;
                        end           
                    end
                end

                // 2. permutate *8
                PT_PERMUTATE: begin
                    if (i < 11) begin // run permutation *8
                        state <= state_o;  // update state after permutation
                        i <= i+1'b1; // inctement round counter
                    end
                    else begin
                        state <= state_o;  // update state after permutation
                        fsm   <= PT_LOAD;
                    end
                end

                ///////////////////////////
                // d. finalization phase //
                ///////////////////////////
                
                // 1. added key in last after last block

                // 2. permutate *12
                F_PERMUTATE: begin
                    if (i < 11) begin
                        state <= state_o;
                        i     <= i + 1'b1;
                    end
                    else begin
                // 3. Tag ready
                        state <= state_o ^ {192'b0, k}; // Tag created in state[127:0]
                        fsm   <= I_NONCE;
                    end
                end

                default: fsm <= I_NONCE;
            endcase
        end
    end

    // Output assignments
    assign ct = (last) ? truncate(state[319:192] ^ data_in, data_length) : (state[319:192] ^ data_in);
    assign ct_valid = (fsm == PT_LOAD) && load;
    assign t = state[127:0];
    assign finish = (fsm == F_PERMUTATE) && (i == 4'd11);

    // Guided Status Flags
    assign ready_for_nonce = (fsm == I_NONCE);
    assign ready_for_key   = (fsm == I_KEY);
    assign ready_for_ad    = (fsm == AD_LOAD);
    assign ready_for_pt    = (fsm == PT_LOAD);

    // Helper function: truncates data according to length (clears trailing bits)
    function [127:0] truncate;
        input [127:0] data;
        input [3:0]   length; // 0 to 15 bytes
        integer j;
        begin
            for (j = 0; j < 16; j = j + 1) begin
                truncate[127 - 8*j -: 8] = (j < length) ? data[127 - 8*j -: 8] : 8'h00;
            end
        end
    endfunction

    // Helper function: pads data by retaining length bytes, inserting 0x80 at boundary, and zeroing the rest
    function [127:0] pad;
        input [127:0] data;
        input [3:0]   length; // 0 to 15 bytes
        integer j;
        begin
            for (j = 0; j < 16; j = j + 1) begin
                if (j < length)
                    pad[127 - 8*j -: 8] = data[127 - 8*j -: 8];
                else if (j == length)
                    pad[127 - 8*j -: 8] = 8'h80;
                else
                    pad[127 - 8*j -: 8] = 8'h00;
            end
        end
    endfunction

endmodule