module spi_slave_pingpong (
    input wire clk_50m,    // Clock rápido interno do FPGA (ex: 100 MHz)
    input wire rst_n,       // Botão de reset (ativo em nível baixo)
    
    // Pinos físicos do SPI (conectados ao ESP32)
    input wire spi_cs,      // Chip Select (ativo baixo)
    input wire spi_sck,     // Clock do SPI vindo do ESP32
    input wire spi_mosi,    // Master Out Slave In (Dado entrando no FPGA)
    output wire spi_miso,     // Master In Slave Out (Dado saindo do FPGA)

    // NOVO: Adicione um pino para o LED
    output wire led_done
);

    // 1. Sincronizadores
    reg [2:0] sck_sync;
    reg [2:0] cs_sync;   // Aumentamos para 3 bits para detectar a subida do CS
    reg [1:0] mosi_sync;

    always @(posedge clk_50m) begin
        sck_sync  <= {sck_sync[1:0], spi_sck};
        cs_sync   <= {cs_sync[1:0], spi_cs};
        mosi_sync <= {mosi_sync[0], spi_mosi};
    end

    // 2. Detectores de Borda
    wire sck_rise  = (sck_sync[2:1] == 2'b01);
    wire sck_fall  = (sck_sync[2:1] == 2'b10);
    wire cs_active = ~cs_sync[1];
    wire cs_rise   = (cs_sync[2:1] == 2'b01); // Dispara quando o CS sobe (ESP32 terminou)

    // 3. Registradores de Dados
    reg [7:0] rx_data;
    reg [7:0] tx_data;
    reg [2:0] bit_cnt;

    // NOVIDADE: MISO ligado diretamente. Assim que o CS for ativado, o Bit 7 já vai pro fio!
    assign spi_miso = (cs_active) ? tx_data[7] : 1'b0;

    // 4. Lógica principal do SPI
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt <= 0;
            tx_data <= 8'hA5; 
            rx_data <= 0;
        end else begin
            
            // Quando a transação acaba (ESP32 solta o pino CS), preparamos o PONG
            if (cs_rise) begin
                tx_data <= ~rx_data; // Inverte o que acabamos de receber!
                bit_cnt <= 0;
            end 
            // Enquanto a transação está ocorrendo...
            else if (cs_active) begin
                
                // Na borda de subida: FPGA LÊ o dado do ESP32
                if (sck_rise) begin
                    rx_data <= {rx_data[6:0], mosi_sync[1]};
                    bit_cnt <= bit_cnt + 1;
                end
                
                // Na borda de descida: FPGA AVANÇA o próximo bit para o ESP32 ler
                if (sck_fall) begin
                    tx_data <= {tx_data[6:0], 1'b0};
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