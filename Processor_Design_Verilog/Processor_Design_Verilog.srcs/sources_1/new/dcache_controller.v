`timescale 1ns / 1ps

module dcache_controller(
    input clk,
    input rst,
    
    // cpu <-> cache
    input [63:0] data_addr,     // address from cpu requesting read/write
    input write,                // cpu write request when 1
    input [63:0] data_wdata,    // data that cpu wants to write to the cache
    input read,                 // cpu read request when 1
    output reg [63:0] data_rdata,   // requested data returned to cpu from cache
    
    // cache <-> main memory
    output reg [63:0] mem_addr,  // address sent to main memory from cache
    output reg [63:0] mem_wdata, // data that cache wants to write to main memory
    input  [63:0] mem_rdata,    // constantly reading data from main memory
    output reg mem_write       // cache write request to main memory when 1
);

    localparam BLOCK_SIZE = 8;        
    localparam CACHE_SIZE = 2048;     // 2KB
    localparam NUM_BLOCKS = CACHE_SIZE / BLOCK_SIZE; // 256 block
    localparam TAG_WIDTH = 61;         

    reg [63:0] cache_data [0:NUM_BLOCKS-1];
    reg [TAG_WIDTH-1:0] cache_tag [0:NUM_BLOCKS-1];
    reg valid [0:NUM_BLOCKS-1];

    reg [7:0] fifo_ptr;

    integer i;
    reg hit;
    reg [7:0] hit_index;
    reg [TAG_WIDTH-1:0] addr_tag;
    //assume memory latency 1 cycle
    always @(posedge clk) begin
        if (rst) begin
            for(i=0; i < NUM_BLOCKS; i=i+1) begin
                cache_data[i] <= 64'b0;
                cache_tag[i] <= 0;
                valid[i] <= 0;
            end
            fifo_ptr <= 0;
            data_rdata <= 64'b0;
            mem_addr <= 64'b0;
            mem_wdata <= 64'b0;
            mem_write <= 0;
        end
        else begin
            hit = 0;
            hit_index = 0;
            addr_tag = data_addr[63:3]; 
            
            for(i=0; i < NUM_BLOCKS; i=i+1) begin
                if(valid[i] && cache_tag[i] == addr_tag) begin
                    hit = 1;
                    hit_index = i[7:0];
                end
            end

            mem_write <= 0;
            mem_addr <= 64'b0;
            mem_wdata <= 64'b0;
            data_rdata <= 64'b0;

            if(read && !write) begin
                if(hit) begin
                    data_rdata <= cache_data[hit_index];
                end
                else begin
                    //read-allocate (updates cache)
                    //add new block with FIFO
                    cache_data[fifo_ptr] <= mem_rdata;
                    cache_tag[fifo_ptr] <= addr_tag;
                    valid[fifo_ptr] <= 1;
                    data_rdata <= mem_rdata;

                    mem_addr <= data_addr; //get data from memory
                    mem_write <= 0;

                    fifo_ptr <= fifo_ptr + 1; //FIFO
                end
            end

            else if(write) begin
                if(hit) begin
                    //write-through
                    cache_data[hit_index] <= data_wdata;
                end
                //No write allocate + write through(memory)
                mem_addr <= data_addr;
                mem_wdata <= data_wdata;
                mem_write <= 1;
                //no reading
                data_rdata <= 64'b0; 
            end
        end
    end

endmodule

