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

    wire [255:0] SHA256_INIT = {
        32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
        32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19
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

    // --- VARIÁVEIS DO HEARTBEAT (MANTIDAS AQUI PARA REATIVAÇÃO FUTURA) ---
    reg [27:0] heartbeat_timer;
    reg        pending_heartbeat;

    sha256_transform core_engine (
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

            // =========================================================================
            // HEARTBEAT (TEMPORIZADOR) - DESATIVADO
            // =========================================================================
            // PARA REATIVAR: Remova as marcações de comentário "/*" e "*/" abaixo
            /*
            if (heartbeat_timer == 28'd250_000_000) begin
                heartbeat_timer <= 28'd0;
                pending_heartbeat <= 1'b1;
            end else begin
                heartbeat_timer <= heartbeat_timer + 1;
            end
            */
            // =========================================================================

            if (new_job_pulse) begin
                nonce <= 32'd0;
                state <= S_START_H1;
            end else begin
                case (state)
                    
                    S_START_H1: begin
                        sha_state_in <= in_midstate;
                        sha_data_in  <= {in_data, nonce, 32'h80000000, 288'b0, 64'd640};
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
                        sha_data_in  <= {hash1_result, 32'h80000000, 160'b0, 64'd256};
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
                        // =========================================================================
                        // CHECAGEM DE DIFICULDADE (COMPATÍVEL COM O FPGAMINER ORIGINAL DE 2011)
                        // =========================================================================
                        // O código original validava os 32 bits (4 bytes) da ponta esquerda.
                        // Para o protocolo Stratum do Bitcoin aceitar um "Share", você precisa usar a 
                        // checagem de 32 bits (4 bytes).
                        //
                        // PARA MUDAR PARA 2 BYTES (16 bits):
                        // Altere a linha abaixo para: if (sha_hash_out[255:240] == 16'h0000) begin
                        //
                        // PARA MUDAR PARA 1 BYTE (8 bits):
                        // Altere a linha abaixo para: if (sha_hash_out[255:248] == 8'h00) begin
                        // =========================================================================
                        if (sha_hash_out[255:240] == 16'h0000) begin 
                            out_nonce   <= nonce;
                            nonce_found <= 1'b1;
                        end

                        // =========================================================================
                        // HEARTBEAT (GATILHO) - DESATIVADO
                        // =========================================================================
                        // PARA REATIVAR: Remova as marcações de comentário "/*" e "*/" abaixo
                        /*
                        else if (pending_heartbeat) begin
                            out_nonce   <= nonce;
                            nonce_found <= 1'b1;
                            pending_heartbeat <= 1'b0;
                        end
                        */
                        // =========================================================================
                        
                        nonce <= nonce + 1;
                        state <= S_START_H1; 
                    end
                    
                    default: state <= S_START_H1;
                endcase
            end
        end
    end
endmodule