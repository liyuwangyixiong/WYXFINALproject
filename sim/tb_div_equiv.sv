`timescale 1ns/1ps
module tb_div_equiv;
    reg clk=0,rst_n=0,start=0;
    always #2.5 clk=~clk;
    reg [63:0] numerator=0,denominator=0;
    wire old_done,new_done;
    wire [63:0] old_q,new_q;
    wyx_spo2_u64_div old_u(.clk(clk),.rst_n(rst_n),.start(start),
        .numerator(numerator),.denominator(denominator),.done(old_done),.quotient(old_q));
    wyx_spo2_u64_div_200 new_u(.clk(clk),.rst_n(rst_n),.start(start),
        .numerator(numerator),.denominator(denominator),.done(new_done),.quotient(new_q));
    reg [63:0] got_old,got_new;
    reg seen_old,seen_new;
    integer i,cycles;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for(i=0;i<40;i=i+1) begin
            @(negedge clk);
            case(i)
                0: begin numerator=0;denominator=0;end
                1: begin numerator=64'hffffffffffffffff;denominator=1;end
                2: begin numerator=64'hffffffffffffffff;denominator=64'hffffffffffffffff;end
                3: begin numerator=1;denominator=64'hffffffffffffffff;end
                default: begin
                    numerator={32'(i*98765431),32'(i*1234567+9)};
                    denominator={32'(i*134567+1),32'(i*21973+3)};
                end
            endcase
            seen_old=0;seen_new=0;start=1;
            @(posedge clk);#0.1;
            if(old_done) begin got_old=old_q;seen_old=1;end
            if(new_done) begin got_new=new_q;seen_new=1;end
            @(negedge clk);start=0;
            for(cycles=0;cycles<205 && !(seen_old && seen_new);cycles=cycles+1) begin
                @(posedge clk);#0.1;
                if(old_done) begin got_old=old_q;seen_old=1;end
                if(new_done) begin got_new=new_q;seen_new=1;end
            end
            if(!seen_old || !seen_new || got_old!==got_new)
                $fatal(1,"division mismatch case=%0d old=%h new=%h seen=%b%b",i,got_old,got_new,seen_old,seen_new);
        end
        $display("DIV_EQUIVALENCE_PASS cases=%0d",i);
        $finish;
    end
endmodule
