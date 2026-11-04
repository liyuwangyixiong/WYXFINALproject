`timescale 1ns/1ps
module tb_filter_equiv;
    reg clk=0,rst_n=0,sample_valid=0;
    always #2.5 clk=~clk; // 200 MHz
    reg [17:0] raw_a=0,raw_b=0;
    wire ref_valid,ref_settled,ref_fault,new_valid,new_settled,new_fault;
    wire [17:0] ref_raw_a,ref_raw_b,new_raw_a,new_raw_b;
    wire signed [23:0] ref_ac_a,ref_ac_b,new_ac_a,new_ac_b;
    wyx_ppg_bandpass_pair ref_u(.clk(clk),.rst_n(rst_n),.sample_valid(sample_valid),
        .raw_a(raw_a),.raw_b(raw_b),.filtered_valid(ref_valid),.settled(ref_settled),
        .arithmetic_fault(ref_fault),.raw_a_aligned(ref_raw_a),.raw_b_aligned(ref_raw_b),
        .ac_a(ref_ac_a),.ac_b(ref_ac_b));
    wyx_ppg_bandpass_pair_200 new_u(.clk(clk),.rst_n(rst_n),.sample_valid(sample_valid),
        .raw_a(raw_a),.raw_b(raw_b),.filtered_valid(new_valid),.settled(new_settled),
        .arithmetic_fault(new_fault),.raw_a_aligned(new_raw_a),.raw_b_aligned(new_raw_b),
        .ac_a(new_ac_a),.ac_b(new_ac_b));
    reg exp_valid,exp_settled,exp_fault;
    reg [17:0] exp_raw_a,exp_raw_b;
    reg signed [23:0] exp_ac_a,exp_ac_b;
    integer i;
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        for(i=0;i<260;i=i+1) begin
            @(negedge clk);
            raw_a=18'd50000+((i*37)%7000);
            raw_b=18'd62000+((i*53)%9000);
            sample_valid=1;
            @(posedge clk); #0.1;
            exp_valid=ref_valid;exp_settled=ref_settled;exp_fault=ref_fault;
            exp_raw_a=ref_raw_a;exp_raw_b=ref_raw_b;exp_ac_a=ref_ac_a;exp_ac_b=ref_ac_b;
            @(negedge clk);sample_valid=0;
            if(i==0) begin
                if(new_raw_a!==exp_raw_a || new_raw_b!==exp_raw_b) $fatal(1,"initial raw mismatch");
            end else begin
                repeat(10) @(posedge clk); #0.1;
                if(new_valid!==exp_valid || new_settled!==exp_settled || new_fault!==exp_fault ||
                   new_raw_a!==exp_raw_a || new_raw_b!==exp_raw_b ||
                   new_ac_a!==exp_ac_a || new_ac_b!==exp_ac_b)
                    $fatal(1,"sample %0d mismatch: ref valid=%b ac=%0d/%0d new valid=%b ac=%0d/%0d",
                        i,exp_valid,exp_ac_a,exp_ac_b,new_valid,new_ac_a,new_ac_b);
            end
            repeat(12) @(posedge clk);
        end
        $display("FILTER_EQUIVALENCE_PASS samples=%0d",i);
        $finish;
    end
endmodule
