`timescale 1ns/1ps
// 每个商位用低半字、高半字、提交三拍计算，保持原64位除法的结果语义。
module wyx_spo2_u64_div_200(
    input wire clk,rst_n,start,
    input wire [63:0] numerator,denominator,
    output reg done,
    output reg [63:0] quotient
);
    localparam [1:0] IDLE=0,LOW=1,HIGH=2,UPDATE=3;
    reg [1:0] state;
    reg [6:0] count;
    reg [63:0] divisor,dividend,q;
    reg [64:0] remainder,shifted_reg;
    reg [32:0] diff_lo;
    reg [33:0] diff_hi;
    wire [64:0] shifted={remainder[63:0],dividend[63]};
    wire ge=!diff_hi[33];
    always @(posedge clk) begin
        done<=0;
        if(!rst_n) begin
            state<=IDLE;count<=0;divisor<=0;dividend<=0;q<=0;
            remainder<=0;shifted_reg<=0;diff_lo<=0;diff_hi<=0;quotient<=0;
        end else case(state)
            IDLE: if(start) begin
                if(denominator==0) begin quotient<=64'hffffffffffffffff;done<=1;end
                else begin
                    count<=0;divisor<=denominator;dividend<=numerator;
                    q<=0;remainder<=0;state<=LOW;
                end
            end
            LOW: begin
                shifted_reg<=shifted;
                diff_lo<={1'b0,shifted[31:0]}-{1'b0,divisor[31:0]};
                state<=HIGH;
            end
            HIGH: begin
                diff_hi<={1'b0,shifted_reg[64:32]}-{2'b0,divisor[63:32]}-diff_lo[32];
                state<=UPDATE;
            end
            UPDATE: begin
                remainder<=ge?{diff_hi[32:0],diff_lo[31:0]}:shifted_reg;
                dividend<=dividend<<1;
                q<={q[62:0],ge};
                if(count==63) begin
                    quotient<={q[62:0],ge};done<=1;state<=IDLE;
                end else begin count<=count+1'b1;state<=LOW;end
            end
        endcase
    end
endmodule
