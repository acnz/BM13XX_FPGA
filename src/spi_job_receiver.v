module spi_miner_interface (
    input wire clk_50m,
    input wire rst_n,
    
    // --- Barramento SPI ---
    input wire spi_cs,
    input wire spi_sck,
    input wire spi_mosi,
    output wire spi_miso,
    output wire led_done,
    
    // --- Para o Motor SHA-256 ---
    output reg [255:0] out_midstate,
    output reg [95:0]  out_data,
    output reg [7:0]   out_job_id,
    output reg         new_job_pulse,
    
    // --- Vindo do Motor SHA-256 ---
    input wire         nonce_found,
    input wire [31:0]  in_nonce
);

    // ====================================================================
    // 1. MINI-FIFO DE NONCES (Capacidade: 4)
    // ====================================================================
    reg [31:0] fifo_mem [0:3];
    reg [2:0]  fifo_count; // Quantos nonces estão guardados
    reg [1:0]  wr_ptr;     // Ponteiro de escrita
    reg [1:0]  rd_ptr;     // Ponteiro de leitura
    
    wire fifo_empty = (fifo_count == 0);
    wire fifo_full  = (fifo_count == 3'd4);
    reg  fifo_pop; // Sinal interno para avisar que o ESP32 leu com sucesso

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            fifo_count <= 0;
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            // ESCRITA: Motor achou um nonce e a prateleira não está cheia
            if (nonce_found && !fifo_full) begin
                fifo_mem[wr_ptr] <= in_nonce;
                wr_ptr <= wr_ptr + 1;
            end
            
            // LEITURA: SPI terminou de ler o nonce e mandou remover da prateleira
            if (fifo_pop && !fifo_empty) begin
                rd_ptr <= rd_ptr + 1;
            end
            
            // Controle seguro da contagem (Trata caso escreva e leia no mesmo clock)
            if (nonce_found && !fifo_full && !(fifo_pop && !fifo_empty)) begin
                fifo_count <= fifo_count + 1;
            end else if (!(nonce_found && !fifo_full) && (fifo_pop && !fifo_empty)) begin
                fifo_count <= fifo_count - 1;
            end
        end
    end

    // ====================================================================
    // 2. SINCRONIZADORES SPI E DETECTORES DE BORDA
    // ====================================================================
    reg [2:0] sck_sync; reg [2:0] cs_sync; reg [1:0] mosi_sync;
    always @(posedge clk_50m) begin
        sck_sync  <= {sck_sync[1:0], spi_sck};
        cs_sync   <= {cs_sync[1:0], spi_cs};
        mosi_sync <= {mosi_sync[0], spi_mosi};
    end
    wire sck_rise = (sck_sync[2:1] == 2'b01);
    wire sck_fall = (sck_sync[2:1] == 2'b10);
    wire cs_active = ~cs_sync[1];
    wire cs_rise   = (cs_sync[2:1] == 2'b01); 

    // ====================================================================
    // 3. PROTOCOLO SPI (OPCODES)
    // ====================================================================
    reg [359:0] shift_reg; // 45 bytes (sem contar o Opcode inicial)
    reg [9:0]   bit_counter;
    reg [7:0]   command;
    reg [7:0]   tx_data;

    assign spi_miso = (cs_active) ? tx_data[7] : 1'b0;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            bit_counter <= 0;
            out_job_id <= 0;
            new_job_pulse <= 0;
            fifo_pop <= 0;
        end else begin
            new_job_pulse <= 0;
            fifo_pop <= 0;

            // FIM DA TRANSAÇÃO
            if (cs_rise) begin
                // Se foi um comando WRITE JOB (0x01) e recebemos 368 bits (8 CMD + 360 DADOS)
                if (command == 8'h01 && bit_counter == 10'd368) begin
                    if (shift_reg[359:352] != out_job_id) begin
                        out_job_id   <= shift_reg[359:352];
                        out_midstate <= shift_reg[351:96];
                        out_data     <= shift_reg[95:0];
                        new_job_pulse <= 1'b1; // Acorda o Motor!
                    end
                end
                // Se foi um comando READ NONCE (0x02) e a transação de 48 bits acabou
                else if (command == 8'h02 && bit_counter == 10'd48) begin
                    if (!fifo_empty) begin
                        fifo_pop <= 1'b1; // Tira o nonce do FIFO, o ESP32 já leu!
                    end
                end
                
                bit_counter <= 0;
            end 
            
            // DURANTE A TRANSAÇÃO
            else if (cs_active) begin
                // --- BORDA DE SUBIDA (LÊ DO ESP32) ---
                if (sck_rise) begin
                    bit_counter <= bit_counter + 1;
                    
                    // Os primeiros 8 bits são o Comando (Opcode)
                    if (bit_counter < 8) begin
                        command <= {command[6:0], mosi_sync[1]};
                    end else begin
                        shift_reg <= {shift_reg[358:0], mosi_sync[1]};
                    end
                end

                // --- BORDA DE DESCIDA (ESCREVE PARA O ESP32) ---
                if (sck_fall) begin
                    // Assim que os 8 primeiros bits chegam, sabemos o comando
                    if (bit_counter == 8 && command == 8'h02) begin
                        // Byte de Status: 1 se tem Nonce, 0 se tá vazio
                        tx_data <= fifo_empty ? 8'h00 : 8'h01; 
                    end
                    else if (bit_counter == 16 && command == 8'h02) begin
                        // Começa a cuspir o Nonce (MSB)
                        tx_data <= fifo_mem[rd_ptr][31:24];
                    end
                    else if (bit_counter == 24 && command == 8'h02) begin
                        tx_data <= fifo_mem[rd_ptr][23:16];
                    end
                    else if (bit_counter == 32 && command == 8'h02) begin
                        tx_data <= fifo_mem[rd_ptr][15:8];
                    end
                    else if (bit_counter == 40 && command == 8'h02) begin
                        tx_data <= fifo_mem[rd_ptr][7:0]; // LSB
                    end
                    else begin
                        // Deslocamento normal bit a bit
                        tx_data <= {tx_data[6:0], 1'b0};
                    end
                end
            end
        end
    end

    // --- TESTE DE CLOCK E RESET ---
    reg [25:0] contador;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            contador <= 0;
        end else begin
            contador <= contador + 1;
        end
    end
    
    // O bit 25 de um contador a 50MHz muda de estado a cada ~0.67 segundos
    assign led_done = contador[25];
endmodule