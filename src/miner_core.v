module miner_core (
    input wire clk_50m,
    input wire rst_n,

    // Interface com o Job Receiver
    input wire         new_job_pulse,
    input wire [255:0] in_midstate,
    input wire [95:0]  in_data,

    // Interface com a FIFO
    output reg         nonce_found,
    output reg [31:0]  out_nonce
);

    reg [31:0] nonce;
    
    // Sinais de controle exclusivos do motor de 2011
    reg [5:0]  cnt;       // Conta de 0 a 63
    reg        feedback;  // 0 = Carrega bloco novo, 1 = Fica girando e calculando

    reg  [255:0] sha_state_in;
    reg  [511:0] sha_data_in;
    wire [255:0] sha_hash_out;

    wire [255:0] SHA256_INIT = {
        32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
        32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19
    };

    reg [3:0] state;
    localparam S_START_H1 = 0;
    localparam S_BUSY_H1  = 1;
    localparam S_LATCH_H1 = 2;
    localparam S_WAIT_H1  = 3;
    localparam S_START_H2 = 4;
    localparam S_BUSY_H2  = 5;
    localparam S_LATCH_H2 = 6;
    localparam S_WAIT_H2  = 7;
    localparam S_CHECK    = 8;

    reg [255:0] hash1_result;

    // Instanciação correta do motor antigo
    sha256_transform #(
        .LOOP(64) // Força o desenrolamento a usar apenas 1 módulo motor
    ) core_engine (
        .clk(clk_50m),
        .feedback(feedback),
        .cnt(cnt),
        .rx_state(sha_state_in),
        .rx_input(sha_data_in),
        .tx_hash(sha_hash_out) // O resultado sai por aqui
    );

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_START_H1;
            nonce <= 32'd0;
            nonce_found <= 1'b0;
            cnt <= 6'd0;
            feedback <= 1'b0;
            out_nonce <= 32'd0;
        end else begin
            nonce_found <= 1'b0; 

            if (new_job_pulse) begin
                nonce <= 32'd0;
                state <= S_START_H1;
            end else begin
                case (state)
                    
                    // --- ETAPA 1: O Primeiro Hash (Midstate) ---
                    S_START_H1: begin
                        sha_state_in <= in_midstate;
                        sha_data_in  <= {in_data, nonce, 32'h80000000, 288'b0, 64'd640};
                        cnt          <= 6'd0;    // Começa na rodada 0
                        feedback     <= 1'b0;    // Diz ao motor: "Engula esses dados!"
                        state        <= S_BUSY_H1;
                    end

                    S_BUSY_H1: begin
                        feedback <= 1'b1;        // Diz ao motor: "Calcule!"
                        cnt <= cnt + 6'd1;
                        // No ciclo 63, o motor estará calculando o último round
                        if (cnt == 6'd63) begin
                            state <= S_LATCH_H1;
                        end
                    end

                    S_LATCH_H1: begin
                        feedback <= 1'b0; 
                        // O truque desse motor: ao descer o feedback para 0, 
                        // ele soma o estado original com o resultado final no próximo clock.
                        state <= S_WAIT_H1;
                    end

                    S_WAIT_H1: begin
                        hash1_result <= sha_hash_out; // Salva o Hash 1 em segurança
                        state <= S_START_H2;
                    end

                    // --- ETAPA 2: O Segundo Hash (Digest) ---
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
                        if (cnt == 6'd63) begin
                            state <= S_LATCH_H2;
                        end
                    end

                    S_LATCH_H2: begin
                        feedback <= 1'b0;
                        state <= S_WAIT_H2;
                    end

                    S_WAIT_H2: begin
                        state <= S_CHECK;
                    end

                    // --- ETAPA 3: Verificar a Vitória ---
                    S_CHECK: begin
                        // O fpgaminer cospe os dados em Big-Endian. A verificação final 
                        // exigirá inverter os bytes, mas para testar o circuito no simulador:
                        if (sha_hash_out[255:240] == 16'h0000) begin 
                            out_nonce   <= nonce;
                            nonce_found <= 1'b1;
                        end
                        
                        nonce <= nonce + 1;
                        state <= S_START_H1; // Vamos de novo!
                    end
                endcase
            end
        end
    end
endmodule