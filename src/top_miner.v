module top_miner (
    input wire clk_50m,    // Pino E2
    input wire rst_n,      // Pino H10 (Botão S2)
    
    // Pinos do SPI para o ESP32
    input wire spi_cs,     // Pino J11
    input wire spi_sck,    // Pino F7
    input wire spi_mosi,   // Pino J8
    output wire spi_miso,   // Pino L9
    output wire led_done   // Pino D7
);

    // =================================================================
    // FIOS INTERNOS (Estes não gastam pinos físicos, ficam no silício!)
    // =================================================================
    wire [255:0] internal_midstate;
    wire [95:0]  internal_data;
    wire [7:0]   internal_job_id;
    wire         internal_new_job_pulse;

    wire         internal_nonce_found;
    wire [31:0]  internal_nonce;

    // =================================================================
    // 1. INSTANCIAMOS A COMUNICAÇÃO SPI (O Carteiro)
    // =================================================================
    spi_miner_interface spi_inst (
        .clk_50m(clk_50m),
        .rst_n(rst_n),
        .spi_cs(spi_cs),
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .led_done(led_done),
        
        // Liga as saídas do SPI nos fios internos
        .out_midstate(internal_midstate),
        .out_data(internal_data),
        .out_job_id(internal_job_id),
        .new_job_pulse(internal_new_job_pulse),
        
        // Liga as entradas vindas do motor
        .nonce_found(internal_nonce_found),
        .in_nonce(internal_nonce)
    );

    // =================================================================
    // 2. INSTANCIAMOS O MOTOR SHA-256 (O Operário)
    // =================================================================
    miner_core core_inst (
        .clk_50m(clk_50m),
        .rst_n(rst_n),
        
        // Recebe os dados do SPI
        .new_job_pulse(internal_new_job_pulse),
        .in_midstate(internal_midstate),
        .in_data(internal_data),
        
        // Devolve os resultados
        .nonce_found(internal_nonce_found),
        .out_nonce(internal_nonce)
    );

endmodule