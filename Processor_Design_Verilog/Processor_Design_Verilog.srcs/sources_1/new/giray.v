`timescale 1ns / 1ps

module giray(
    input clk_i,
    input rst_i,
    input [31:0] inst_i,
    input [31:0] data_mem_rdata_i,
    output reg data_mem_we_o,
    output reg [31:0] pc_o,
    output [1023:0] regs_o,
    output reg [31:0] data_mem_addr_o,
    output reg [31:0] data_mem_wdata_o,
    output reg [1:0] cur_stage_o
);

    reg [31:0] regs [0:31];
    wire [31:0] inst = {inst_i[7:0], inst_i[15:8], inst_i[23:16], inst_i[31:24]};

    localparam FETCH     = 2'b00;
    localparam DECODE    = 2'b01;
    localparam EXECUTE   = 2'b10;
    localparam WRITEBACK = 2'b11;

    reg [1:0] stage = FETCH;
    reg [3:0] exe_counter; 
    reg [1:0] repeat_c;    

    wire [4:0] rs1    = inst[19:15];
    wire [4:0] rs2    = inst[24:20];
    wire [4:0] rd     = inst[11:7];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];
    wire [6:0] opcode = inst[6:0];

    // İşaret genişletmeleri
    wire [31:0] imm12         = {{20{inst[31]}}, inst[31:20]}; // imm_i
    wire [31:0] branch_offset = {{20{inst[11]}}, inst[7], inst[29:25], inst[11:8], 1'b0};
    wire [31:0] s_imm         = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] b_imm         = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] u_imm         = {inst[31:12], 12'b0};
    wire [31:0] j_imm         = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};

    wire s1 = inst[31];
    wire [1:0] s2 = inst[31:30];

    wire [7:0] pattern = regs[rs2][7:0];
    wire [24:0] match_bits;
    wire match_found = |match_bits;

    reg [31:0] mac_rs1_addr;
    reg [31:0] mac_rs2_addr;
    reg [1:0] max_repeats;
    reg [31:0] mac_imm_addr;
    reg [31:0] pc_next;
    reg [31:0] alu_result;
    reg [31:0] wb_value;
    reg [4:0] current_rd;
    reg take_branch;
    integer i;

    reg [31:0] val0, val1, val2;
    reg [31:0] val_rs1, val_rs2, val_mem;

    genvar k;
    generate
        for(k = 0; k < 25; k=k+1) begin
            assign match_bits[k] = (regs[rs1][k+7 : k] == pattern);
        end
    endgenerate

    genvar j;
    generate
        for(j = 0; j < 32; j=j+1) begin 
           assign regs_o[j*32 +: 32] = regs[j];
        end
    endgenerate

    always @(posedge clk_i) begin
        cur_stage_o   <= stage;
        data_mem_we_o <= 1'b0;
        pc_next       <= pc_o + 4;
        
        if (rst_i) begin
            pc_o        <= 32'b0;
            stage       <= FETCH;
            exe_counter <= 4'd0;
            repeat_c    <= 2'd0;
            
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'b0;
        end
        else begin
            case (stage) 
                FETCH: begin
                    data_mem_addr_o <= pc_o;
                    stage           <= DECODE;
                end

                DECODE: begin
                    current_rd  <= rd;
                    exe_counter <= 4'd1; 
                    repeat_c    <= 2'd0;

                    if (opcode == 7'b1111111 && funct3 == 3'b111) begin
                        // MAC.LD.ST
                        max_repeats  <= s2 + 2'b01;
                        mac_rs1_addr <= regs[rs1];
                        mac_rs2_addr <= regs[rs2];
                        mac_imm_addr <= b_imm;
                    end

                    stage <= EXECUTE;
                end

                EXECUTE: begin
                    if (opcode == 7'b1110111 && funct3 == 3'b000) begin
                        // SUB.ABS
                        if (regs[rs1] >= regs[rs2])
                            wb_value <= regs[rs1] - regs[rs2];
                        else
                            wb_value <= regs[rs2] - regs[rs1];

                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1110111 && funct3 == 3'b100) begin
                        // AVG.FLR
                        alu_result  <= regs[rs1] + imm12;
                        wb_value    <= (regs[rs1] + imm12) >> 1;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1110111 && funct3 == 3'b101) begin
                        // MOVU
                        wb_value    <= {20'b0, imm12[11:0]};
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1110111 && funct3 == 3'b001) begin
                        // SRT.CMP.ST
                        if ($signed(regs[rs1]) < $signed(regs[rs2])) begin
                            val0 <= regs[rs1];
                            val1 <= regs[rs2];
                        end else begin
                            val0 <= regs[rs2];
                            val1 <= regs[rs1];
                        end

                        if (exe_counter == 4'd1) begin
                            data_mem_we_o    <= 1'b1;   
                            data_mem_addr_o  <= regs[current_rd];  
                            data_mem_wdata_o <= ($signed(regs[rs1]) < $signed(regs[rs2])) ? regs[rs1] : regs[rs2];
                            exe_counter      <= 4'd2;
                        end
                        else if (exe_counter == 4'd2) begin
                            data_mem_we_o    <= 1'b1;
                            data_mem_addr_o  <= regs[current_rd] + 4;  
                            data_mem_wdata_o <= ($signed(regs[rs1]) < $signed(regs[rs2])) ? regs[rs2] : regs[rs1];
                            exe_counter      <= 4'd3;
                            stage            <= WRITEBACK;
                        end
                        else begin
                            exe_counter <= 4'd0;
                            stage       <= WRITEBACK;
                        end
                    end

                    else if (opcode == 7'b1110111 && funct3 == 3'b110) begin
                        // LD.CMP.MAX
                        if (exe_counter == 4'd1) begin
                            data_mem_addr_o <= regs[rs1];
                            exe_counter     <= 4'd2;
                        end
                        else if (exe_counter == 4'd2) begin
                            val0            <= data_mem_rdata_i;
                            data_mem_addr_o <= regs[rs2];
                            exe_counter     <= 4'd3;
                        end
                        else if (exe_counter == 4'd3) begin
                            val1            <= data_mem_rdata_i;
                            data_mem_addr_o <= regs[current_rd];
                            exe_counter     <= 4'd4;
                        end
                        else if (exe_counter == 4'd4) begin
                            val2        <= data_mem_rdata_i;
                            exe_counter <= 4'd5;
                        end
                        else begin
                            wb_value <= (val2 > val1) ? ((val2 > val0) ? val2 : val0) : ((val1 > val0) ? val1 : val0);
                            exe_counter <= 4'd0;
                            stage       <= WRITEBACK;
                        end
                    end

                    else if (opcode == 7'b1110111 && funct3 == 3'b111) begin
                        // SRCH.BIT.PTRN   
                        wb_value    <= match_found ? 32'd1 : 32'd0;
                        exe_counter <= 4'd0;        
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1110111 && funct3 == 3'b010) begin
                        // SEL.PART
                        if (s1)
                            wb_value <= {16'b0, regs[rs1][31:16]};
                        else
                            wb_value <= {16'b0, regs[rs1][15:0]};

                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1111111 && funct3 == 3'b000) begin
                        // SEL.CND
                        case (s2)
                            2'b00: take_branch <= ($signed(regs[rs1]) == $signed(regs[rs2]));
                            2'b01: take_branch <= ($signed(regs[rs1]) >= $signed(regs[rs2]));
                            2'b10: take_branch <= ($signed(regs[rs1]) < $signed(regs[rs2]));
                            2'b11: take_branch <= 1'b0;
                        endcase

                        if (take_branch)
                            pc_next <= pc_o + branch_offset;
                        else
                            pc_next <= pc_o + 4;

                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end                        

                    else if (opcode == 7'b1111111 && funct3 == 3'b111) begin
                        // MAC.LD.ST
                        case (exe_counter)
                            4'b0001: begin                          
                                data_mem_addr_o <= mac_rs1_addr;
                                exe_counter     <= 4'd2;
                            end
                            4'b0010: begin
                                val_rs1         <= data_mem_rdata_i;
                                data_mem_addr_o <= mac_rs2_addr;
                                exe_counter     <= 4'd3;
                            end
                            4'b0011: begin
                                val_rs2         <= data_mem_rdata_i;
                                data_mem_addr_o <= mac_imm_addr;
                                exe_counter     <= 4'd4;
                            end
                            4'b0100: begin
                                val_mem          <= data_mem_rdata_i;
                                alu_result       <= data_mem_rdata_i + (val_rs1 * val_rs2);
                                data_mem_we_o    <= 1'b1;
                                data_mem_addr_o  <= mac_imm_addr;
                                data_mem_wdata_o <= data_mem_rdata_i + (val_rs1 * val_rs2);

                                if (repeat_c < max_repeats - 1) begin
                                    repeat_c     <= repeat_c + 1'b1;
                                    mac_rs1_addr <= mac_rs1_addr + 4;
                                    mac_rs2_addr <= mac_rs2_addr + 4;
                                    exe_counter  <= 4'd1;
                                end else begin
                                    exe_counter <= 4'd0;
                                    stage       <= WRITEBACK;
                                end
                            end
                        endcase
                    end

                    else if (opcode == 7'b0010011 && funct3 == 3'b000) begin
                        // ADDI
                        wb_value    <= regs[rs1] + imm12;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0010011 && funct3 == 3'b011) begin
                        // SLTIU
                        wb_value    <= (regs[rs1] < imm12) ? 32'd1 : 32'd0;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0010011 && funct3 == 3'b100) begin
                        // XORI
                        wb_value    <= regs[rs1] ^ imm12;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0010011 && funct3 == 3'b001 && funct7 == 7'b0000000) begin
                        // SLLI
                        wb_value    <= regs[rs1] << imm12[4:0];
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0000011 && funct3 == 3'b010) begin
                        // LW (2 çevrimli bellek okuması)
                        if (exe_counter == 4'd1) begin
                            data_mem_addr_o <= regs[rs1] + imm12;
                            exe_counter     <= 4'd2;
                        end
                        else begin
                            wb_value    <= data_mem_rdata_i;
                            exe_counter <= 4'd0;
                            stage       <= WRITEBACK;
                        end
                    end

                    else if (opcode == 7'b0100011 && funct3 == 3'b010) begin
                        // SW
                        data_mem_addr_o  <= regs[rs1] + s_imm;
                        data_mem_wdata_o <= regs[rs2];
                        data_mem_we_o    <= 1'b1;
                        exe_counter      <= 4'd0;
                        stage            <= WRITEBACK;
                    end

                    else if (opcode == 7'b0110011 && funct3 == 3'b000 && funct7 == 7'b0000000) begin
                        // ADD
                        wb_value    <= regs[rs1] + regs[rs2];
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0110011 && funct3 == 3'b000 && funct7 == 7'b0100000) begin
                        // SUB
                        wb_value    <= regs[rs1] - regs[rs2];
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0110011 && funct3 == 3'b010 && funct7 == 7'b0000000) begin
                        // SLT
                        wb_value    <= ($signed(regs[rs1]) < $signed(regs[rs2])) ? 32'd1 : 32'd0;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0110011 && funct3 == 3'b011 && funct7 == 7'b0000000) begin
                        // SLTU
                        wb_value    <= (regs[rs1] < regs[rs2]) ? 32'd1 : 32'd0;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0110011 && funct3 == 3'b101 && funct7 == 7'b0100000) begin
                        // SRA
                        wb_value    <= $signed(regs[rs1]) >>> regs[rs2][4:0];
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0110011 && funct3 == 3'b111 && funct7 == 7'b0000000) begin
                        // AND
                        wb_value    <= regs[rs1] & regs[rs2];
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0110111) begin
                        // LUI
                        wb_value    <= u_imm;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b0010111) begin
                        // AUIPC
                        wb_value    <= pc_o + u_imm;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1101111) begin
                        // JAL
                        wb_value <= pc_o + 4;
                        pc_next  <= pc_o + j_imm;
                        stage    <= WRITEBACK;
                    end

                    else if (opcode == 7'b1100111 && funct3 == 3'b000) begin
                        // JALR
                        wb_value    <= pc_o + 4;
                        pc_next     <= (regs[rs1] + imm12) & 32'hFFFFFFFE;
                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1100011 && funct3 == 3'b000) begin
                        // BEQ
                        take_branch <= (regs[rs1] == regs[rs2]);
                        if (regs[rs1] == regs[rs2])
                            pc_next <= pc_o + b_imm;

                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end

                    else if (opcode == 7'b1100011 && funct3 == 3'b101) begin
                        // BGE
                        take_branch <= ($signed(regs[rs1]) >= $signed(regs[rs2]));
                        if ($signed(regs[rs1]) >= $signed(regs[rs2]))
                            pc_next <= pc_o + b_imm;

                        exe_counter <= 4'd0;
                        stage       <= WRITEBACK;
                    end
                end

                WRITEBACK: begin
                    // x0 yazmacını katı koruma altına alma (asla x0'a yazılamaz)
                    if (current_rd != 5'd0 && 
                        opcode != 7'b0100011 && 
                        opcode != 7'b1100011 && 
                        !(opcode == 7'b1111111 && funct3 == 3'b111) && 
                        !(opcode == 7'b1110111 && funct3 == 3'b001)) begin

                        regs[current_rd] <= wb_value;
                    end

                    // her halükarda x0 = 0 tutulur
                    regs[0] <= 32'b0;

                    pc_o  <= pc_next;
                    stage <= FETCH;
                end
            endcase    
        end
    end

endmodule
