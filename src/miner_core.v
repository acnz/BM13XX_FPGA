module miner_core (
    input wire clk_50m,
    input wire rst_n,

    input wire         new_job_pulse,
    input wire [255:0] in_midstate,
    input wire [95:0]  in_data,

    output reg         nonce_found,
    output reg [31:0]  out_nonce
);

    reg [31:0] nonce;
    reg [5:0]  cnt;       
    reg        feedback;  

    reg  [255:0] sha_state_in;
    reg  [511:0] sha_data_in;
    wire [255:0] sha_hash_out;

    // A mágica de Endianness da V1 do SHA256_INIT (H[0] deve ficar em [31:0])
    wire [255:0] SHA256_INIT = {
        32'h5be0cd19, // H[7]
        32'h1f83d9ab, // H[6]
        32'h9b05688c, // H[5]
        32'h510e527f, // H[4]
        32'ha54ff53a, // H[3]
        32'h3c6ef372, // H[2]
        32'hbb67ae85, // H[1]
        32'h6a09e667  // H[0]
    };

    reg [3:0] state;
    localparam S_START_H1  = 0;
    localparam S_BUSY_H1   = 1;
    localparam S_LATCH_H1  = 2;
    localparam S_WAIT_H1_A = 3;  
    localparam S_WAIT_H1_B = 4;  
    localparam S_START_H2  = 5;
    localparam S_BUSY_H2   = 6;
    localparam S_LATCH_H2  = 7;
    localparam S_WAIT_H2_A = 8;  
    localparam S_WAIT_H2_B = 9;  
    localparam S_CHECK     = 10;

    reg [255:0] hash1_result;

    reg [27:0] heartbeat_timer;
    reg        pending_heartbeat;

    // O Nonce precisa ser Invertido (Little para Big Endian) para o cálculo do bloco
    wire [31:0] nonce_swapped = {nonce[7:0], nonce[15:8], nonce[23:16], nonce[31:24]};

    sha256_transform #(
        .LOOP(64) 
    ) core_engine (
        .clk(clk_50m),
        .feedback(feedback),
        .cnt(cnt),
        .rx_state(sha_state_in),
        .rx_input(sha_data_in),
        .tx_hash(sha_hash_out) 
    );

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_START_H1;
            nonce <= 32'd0;
            nonce_found <= 1'b0;
            cnt <= 6'd0;
            feedback <= 1'b0;
            out_nonce <= 32'd0;
            heartbeat_timer <= 28'd0;
            pending_heartbeat <= 1'b0;
        end else begin
            nonce_found <= 1'b0; 

            if (heartbeat_timer == 28'd250_000_000) begin
                heartbeat_timer <= 28'd0;
                pending_heartbeat <= 1'b1; 
            end else begin
                heartbeat_timer <= heartbeat_timer + 1;
            end

            if (new_job_pulse) begin
                nonce <= 32'd0;
                state <= S_START_H1;
            end else begin
                case (state)
                    
                    S_START_H1: begin
                        // Inversão Absoluta: Colocamos H[0] em 31:0
                        sha_state_in <= {
                            in_midstate[31:0],
                            in_midstate[63:32],
                            in_midstate[95:64],
                            in_midstate[127:96],
                            in_midstate[159:128],
                            in_midstate[191:160],
                            in_midstate[223:192],
                            in_midstate[255:224]
                        };
                        
                        // Mapeamento milimétrico do Bloco de 512 bits
                        sha_data_in  <= {
                            32'd640,           // W[15] - Tamanho
                            32'd0,             // W[14]
                            288'd0,            // W[13..5] - Padding
                            32'h80000000,      // W[4]  - Início do Padding
                            nonce_swapped,     // W[3]  - Nonce
                            in_data[31:0],     // W[2]  - Data Final
                            in_data[63:32],    // W[1]  - Data Meio
                            in_data[95:64]     // W[0]  - Data Início
                        };
                        
                        cnt          <= 6'd0;    
                        feedback     <= 1'b0;    
                        state        <= S_BUSY_H1;
                    end

                    S_BUSY_H1: begin
                        feedback <= 1'b1;        
                        cnt <= cnt + 6'd1;
                        if (cnt == 6'd63) state <= S_LATCH_H1;
                    end

                    S_LATCH_H1: begin
                        feedback <= 1'b0; 
                        state <= S_WAIT_H1_A;
                    end

                    S_WAIT_H1_A: state <= S_WAIT_H1_B;

                    S_WAIT_H1_B: begin
                        hash1_result <= sha_hash_out; 
                        state <= S_START_H2;
                    end

                    S_START_H2: begin
                        sha_state_in <= SHA256_INIT;
                        sha_data_in  <= {
                            32'd256,        // W[15]
                            32'd0,          // W[14]
                            160'd0,         // W[13..9]
                            32'h80000000,   // W[8]
                            hash1_result    // W[7..0]
                        };
                        cnt          <= 6'd0;
                        feedback     <= 1'b0;
                        state        <= S_BUSY_H2;
                    end

                    S_BUSY_H2: begin
                        feedback <= 1'b1;
                        cnt <= cnt + 6'd1;
                        if (cnt == 6'd63) state <= S_LATCH_H2;
                    end

                    S_LATCH_H2: begin
                        feedback <= 1'b0;
                        state <= S_WAIT_H2_A;
                    end

                    S_WAIT_H2_A: state <= S_WAIT_H2_B;

                    S_WAIT_H2_B: state <= S_CHECK;

                    S_CHECK: begin
                        // Verificamos a dificuldade 12'h000 (3 Zeros Hex) em H2[7] MSB
                        // Como a probabilidade é 1/4096, você verá muitos shares REAIS!
                        if (sha_hash_out[255:244] == 12'h000 || pending_heartbeat) begin 
                            out_nonce   <= nonce;
                            nonce_found <= 1'b1;
                            pending_heartbeat <= 1'b0;
                        end
                        
                        nonce <= nonce + 1;
                        state <= S_START_H1; 
                    end
                    
                    default: state <= S_START_H1;
                endcase
            end
        end
    end
endmodule