module spi_slave_pingpong (
    input wire clk_50m,    // Clock rápido interno do FPGA (ex: 100 MHz)
    input wire rst_n,       // Botão de reset (ativo em nível baixo)
    
    // Pinos físicos do SPI (conectados ao ESP32)
    input wire spi_cs,      // Chip Select (ativo baixo)
    input wire spi_sck,     // Clock do SPI vindo do ESP32
    input wire spi_mosi,    // Master Out Slave In (Dado entrando no FPGA)
    output reg spi_miso     // Master In Slave Out (Dado saindo do FPGA)
);

    // 1. Sincronizadores (Para evitar Metaestabilidade e ruídos dos cabos)
    reg [2:0] sck_sync;
    reg [1:0] cs_sync;
    reg [1:0] mosi_sync;

    always @(posedge clk_50m) begin
        sck_sync  <= {sck_sync[1:0], spi_sck};
        cs_sync   <= {cs_sync[0], spi_cs};
        mosi_sync <= {mosi_sync[0], spi_mosi};
    end

    // 2. Detectores de Borda (A mágica da Sobreamostragem)
    // Compara o estado atual com o estado anterior para achar a borda exata
    wire sck_rise = (sck_sync[2:1] == 2'b01); // Borda de subida
    wire sck_fall = (sck_sync[2:1] == 2'b10); // Borda de descida
    wire cs_active = ~cs_sync[1];             // CS é ativo em 0

    // 3. Registradores de Dados
    reg [7:0] rx_data; // Armazena o que o ESP32 enviou
    reg [7:0] tx_data; // Armazena o que o FPGA vai responder (o Pong)
    reg [2:0] bit_cnt; // Conta de 0 a 7 (8 bits)

    // 4. Lógica principal do SPI
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt <= 0;
            spi_miso <= 0;
            tx_data <= 8'hA5; // Primeiro byte que o FPGA dirá ao ESP32
            rx_data <= 0;
        end else begin
            if (cs_active) begin
                
                // Na Borda de SUBIDA: FPGA lê o dado (MOSI)
                if (sck_rise) begin
                    rx_data <= {rx_data[6:0], mosi_sync[1]}; // Shift-left
                    bit_cnt <= bit_cnt + 1;
                    
                    // Se foi o último bit do byte, prepara o "Pong"
                    if (bit_cnt == 3'd7) begin
                        // A operação do PING-PONG: invertemos o dado recebido!
                        tx_data <= ~{rx_data[6:0], mosi_sync[1]}; 
                    end
                end
                
                // Na Borda de DESCIDA: FPGA escreve o dado (MISO)
                if (sck_fall) begin
                    spi_miso <= tx_data[7]; // Manda o bit mais significativo
                    tx_data <= {tx_data[6:0], 1'b0}; // Shift-left para o próximo bit
                end
                
            end else begin
                // Se CS está inativo (alto), zera o contador
                bit_cnt <= 0;
            end
        end
    end

endmodule