module spi_miner_interface (
    input wire clk_50m,
    input wire rst_n,
    
    input wire spi_cs,
    input wire spi_sck,
    input wire spi_mosi,
    output wire spi_miso,
    output wire led_done, // O seu LED de diagnóstico!
    
    output reg [255:0] out_midstate,
    output reg [95:0]  out_data,
    output reg [7:0]   out_job_id,
    output reg         new_job_pulse,
    
    input wire         nonce_found,
    input wire [31:0]  in_nonce
);

    // ====================================================================
    // 1. MINI-FIFO DE NONCES
    // ====================================================================
    reg [31:0] fifo_mem [0:3];
    reg [2:0]  fifo_count; 
    reg [1:0]  wr_ptr;
    reg [1:0]  rd_ptr;
    
    wire fifo_empty = (fifo_count == 0);
    wire fifo_full  = (fifo_count == 3'd4);
    reg  fifo_pop; 

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            fifo_count <= 0; wr_ptr <= 0; rd_ptr <= 0;
        end else begin
            if (nonce_found && !fifo_full) begin
                fifo_mem[wr_ptr] <= in_nonce; wr_ptr <= wr_ptr + 1;
            end
            if (fifo_pop && !fifo_empty) begin
                rd_ptr <= rd_ptr + 1;
            end
            if (nonce_found && !fifo_full && !(fifo_pop && !fifo_empty)) fifo_count <= fifo_count + 1;
            else if (!(nonce_found && !fifo_full) && (fifo_pop && !fifo_empty)) fifo_count <= fifo_count - 1;
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
    // 3. PROTOCOLO SPI & CRC5
    // ====================================================================
    reg [367:0] shift_reg; // 46 bytes de Payload
    reg [9:0]   bit_counter;
    reg [7:0]   command;
    reg [7:0]   tx_data;

    // Registradores e Flags do CRC
    reg [4:0] rx_crc;
    reg [4:0] tx_crc;
    reg       rx_crc_error; // Aciona o Pânico no LED!

    wire rx_inv = mosi_sync[1] ^ rx_crc[4];
    wire tx_inv = spi_miso ^ tx_crc[4]; // O CRC TX lê do próprio pino de saída!

    assign spi_miso = (cs_active) ? tx_data[7] : 1'b0;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            bit_counter <= 0; out_job_id <= 0; new_job_pulse <= 0; fifo_pop <= 0;
            rx_crc_error <= 0; rx_crc <= 5'h1F; tx_crc <= 5'h1F;
        end else begin
            new_job_pulse <= 0; fifo_pop <= 0;

            if (cs_rise) begin
                // CHECAGEM DO PACOTE RECEBIDO (Write Job = 47 bytes = 376 bits)
                if (command == 8'h01 && bit_counter == 10'd376) begin
                    // Compara o CRC calculado (rx_crc) com o byte 47 que chegou (shift_reg[4:0])
                    if (rx_crc == shift_reg[4:0]) begin
                        rx_crc_error <= 1'b0; // Sucesso! LED Normal.
                        
                        if (shift_reg[367:360] != out_job_id) begin
                            out_job_id   <= shift_reg[367:360];
                            out_midstate <= shift_reg[359:104];
                            out_data     <= shift_reg[103:8];
                            new_job_pulse <= 1'b1;
                        end
                    end else begin
                        rx_crc_error <= 1'b1; // ERRO! LED Pisca Rápido!
                    end
                end
                else if (command == 8'h02 && bit_counter == 10'd56) begin
                    if (!fifo_empty) fifo_pop <= 1'b1;
                end
                
                bit_counter <= 0; rx_crc <= 5'h1F; // Reseta para a próxima transação
            end 
            
            else if (cs_active) begin
                // --- BORDA DE SUBIDA (FPGA LÊ) ---
                if (sck_rise) begin
                    bit_counter <= bit_counter + 1;
                    
                    if (bit_counter < 8) command <= {command[6:0], mosi_sync[1]};
                    else shift_reg <= {shift_reg[366:0], mosi_sync[1]};

                    // Calcula o CRC RX nos primeiros 368 bits (46 bytes)
                    if (bit_counter < 368) begin
                        rx_crc[0] <= rx_inv;
                        rx_crc[1] <= rx_crc[0];
                        rx_crc[2] <= rx_crc[1] ^ rx_inv;
                        rx_crc[3] <= rx_crc[2];
                        rx_crc[4] <= rx_crc[3];
                    end

                    // Calcula o CRC TX enquanto o FPGA devolve o Status e o Nonce (bits 8 a 47)
                    if (command == 8'h02 && bit_counter >= 8 && bit_counter < 48) begin
                        tx_crc[0] <= tx_inv;
                        tx_crc[1] <= tx_crc[0];
                        tx_crc[2] <= tx_crc[1] ^ tx_inv;
                        tx_crc[3] <= tx_crc[2];
                        tx_crc[4] <= tx_crc[3];
                    end
                end

                // --- BORDA DE DESCIDA (FPGA ESCREVE) ---
                if (sck_fall) begin
                    if (bit_counter == 8 && command == 8'h02) begin
                        tx_data <= fifo_empty ? 8'h00 : 8'h01; 
                        tx_crc <= 5'h1F; // Garante o reset do CRC TX no início do pacote
                    end
                    else if (bit_counter == 16 && command == 8'h02) tx_data <= fifo_mem[rd_ptr][31:24];
                    else if (bit_counter == 24 && command == 8'h02) tx_data <= fifo_mem[rd_ptr][23:16];
                    else if (bit_counter == 32 && command == 8'h02) tx_data <= fifo_mem[rd_ptr][15:8];
                    else if (bit_counter == 40 && command == 8'h02) tx_data <= fifo_mem[rd_ptr][7:0];
                    else if (bit_counter == 48 && command == 8'h02) begin
                        // A MAGIA ACONTECE AQUI! Manda o CRC calculado para o ESP32 ler
                        tx_data <= {3'b000, tx_crc};
                    end
                    else tx_data <= {tx_data[6:0], 1'b0};
                end
            end
        end
    end

    // ====================================================================
    // 4. LÓGICA DO LED DE DIAGNÓSTICO (VIVO / PÂNICO)
    // ====================================================================
    reg [25:0] contador;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) contador <= 0;
        else contador <= contador + 1;
    end
    
    // Se teve erro de CRC, usa o bit 23 (Pisca ~6 vezes por seg). Se tudo OK, bit 25 (Pisca ~1.5x por seg)
    assign led_done = rx_crc_error ? contador[23] : contador[25];

endmodule