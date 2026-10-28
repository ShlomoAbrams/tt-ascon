// ascon round module:
module ascon_round(
    input   wire [7:0]      round_c,    // round constant
    input   wire [319:0]    state_i,    // input state 
    output  wire [319:0]    state_o     // permuted state
);

    // wires:
    wire [63:0] s0, s1, s2, s3, s4;  // inner state
    wire [63:0] s2_c;                // constant layer output
    wire [63:0] x0, x1, x2, x3, x4;  // substitution layer signals
    wire [63:0] t0, t1, t2, t3, t4;
    wire [63:0] y0, y1, y2, y3, y4;
    wire [63:0] s0_next, s1_next, s2_next, s3_next, s4_next; // diffusion outputs       // outputs of linear diffusion layer

    // unpack state:
    
    assign s0 = state_i[319:256];
    assign s1 = state_i[255:192];
    assign s2 = state_i[191:128];
    assign s3 = state_i[127:64];
    assign s4 = state_i[63:0];
    
    // 1. permutation constant addition layer:   
    assign s2_c = s2 ^ {56'b0,round_c}; // add constant to the state

    // 2. permutation substituion layer:
    // a) xor 3 states 
    assign x0 = s0 ^ s4;
    assign x1 = s1; 
    assign x2 = s2_c ^ s1;
    assign x3 = s3;
    assign x4 = s4 ^ s3; 
    // b) xor all states
    assign t0 = x0 ^ (~x1 & x2);
    assign t1 = x1 ^ (~x2 & x3);
    assign t2 = x2 ^ (~x3 & x4);
    assign t3 = x3 ^ (~x4 & x0);
    assign t4 = x4 ^ (~x0 & x1); 
    // b) xor 3 states and invert 1 state 
    assign y0 = t0 ^ t4;
    assign y1 = t0 ^ t1;
    assign y2 = ~t2;
    assign y3 = t3 ^ t2;
    assign y4 = t4; 

    // 3. permutation linear diffusion layer:
    assign s0_next = y0 ^ {y0[18:0], y0[63:19]} ^ {y0[27:0], y0[63:28]};    // y0 ^ (y0>>19) ^ (y0>>28)
    assign s1_next = y1 ^ {y1[60:0], y1[63:61]} ^ {y1[38:0], y1[63:39]};    // y1 ^ (y1>>61) ^ (y1>>39)
    assign s2_next = y2 ^ {y2[0], y2[63:1]}     ^ {y2[5:0], y2[63:6]};      // y2 ^ (y2>>1) ^ (y2>>6)
    assign s3_next = y3 ^ {y3[9:0], y3[63:10]}  ^ {y3[16:0], y3[63:17]};    // y3 ^ (y3>>10) ^ (y3>>17)
    assign s4_next = y4 ^ {y4[6:0], y4[63:7]}   ^ {y4[40:0], y4[63:41]};    // y4 ^ (y4>>7) ^ (y4>>41)

    // update output:
    assign state_o = {s0_next,s1_next,s2_next,s3_next,s4_next};

endmodule