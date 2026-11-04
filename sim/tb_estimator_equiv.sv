`timescale 1ns/1ps
module tb_estimator_equiv;
    reg clk=0,rst_n=0,sample_valid=0,stream_online=1;
    always #2.5 clk=~clk;
    reg [17:0] red_raw=0,ir_raw=0;
    reg signed [23:0] red_ac_filtered=0,ir_ac_filtered=0;
    wire old_valid,old_good,old_event,new_valid,new_good,new_event;
    wire [15:0] old_spo2,new_spo2,old_corr,new_corr,old_period,new_period;
    wire [7:0] old_reject,new_reject;
    wire [31:0] old_ratio,new_ratio;
    wyx_spo2_estimator old_u(.clk(clk),.rst_n(rst_n),.tick_1ms(1'b0),
        .sample_valid(sample_valid),.stream_online(stream_online),.stream_overflow(1'b0),
        .red_raw(red_raw),.ir_raw(ir_raw),.red_ac_filtered(red_ac_filtered),.ir_ac_filtered(ir_ac_filtered),
        .estimate_valid(old_valid),.estimate_good(old_good),.spo2_x100(old_spo2),
        .result_event(old_event),.reject_reason(old_reject),.ratio_q16(old_ratio),
        .correlation_bp(old_corr),.period_samples(old_period));
    wyx_spo2_estimator_200 new_u(.clk(clk),.rst_n(rst_n),.tick_1ms(1'b0),
        .sample_valid(sample_valid),.stream_online(stream_online),.stream_overflow(1'b0),
        .red_raw(red_raw),.ir_raw(ir_raw),.red_ac_filtered(red_ac_filtered),.ir_ac_filtered(ir_ac_filtered),
        .estimate_valid(new_valid),.estimate_good(new_good),.spo2_x100(new_spo2),
        .result_event(new_event),.reject_reason(new_reject),.ratio_q16(new_ratio),
        .correlation_bp(new_corr),.period_samples(new_period));
    integer i,k,shape;
    reg seen_old=0,seen_new=0;
    reg [15:0] got_old_spo2,got_new_spo2,got_old_corr,got_new_corr,got_old_period,got_new_period;
    reg [7:0] got_old_reject,got_new_reject;
    reg [31:0] got_old_ratio,got_new_ratio;
    reg got_old_good,got_new_good;
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<400;i=i+1) begin
            shape=i%100;
            if(shape>=50) shape=100-shape;
            @(negedge clk);
            red_ac_filtered=(shape-25)*180;
            ir_ac_filtered=(shape-25)*210;
            red_raw=18'd50000+((shape-25)*180);
            ir_raw=18'd60000+((shape-25)*210);
            sample_valid=1;
            @(negedge clk);sample_valid=0;
            repeat(18) @(posedge clk);
        end
        for(k=0;k<220000 && !(seen_old && seen_new);k=k+1) begin
            @(posedge clk);#0.1;
            if(old_event) begin
                seen_old=1;got_old_good=old_good;got_old_spo2=old_spo2;got_old_reject=old_reject;
                got_old_ratio=old_ratio;got_old_corr=old_corr;got_old_period=old_period;
            end
            if(new_event) begin
                seen_new=1;got_new_good=new_good;got_new_spo2=new_spo2;got_new_reject=new_reject;
                got_new_ratio=new_ratio;got_new_corr=new_corr;got_new_period=new_period;
            end
        end
        if(!seen_old || !seen_new) $fatal(1,"result timeout old=%b new=%b",seen_old,seen_new);
        if(got_old_good!==got_new_good || got_old_spo2!==got_new_spo2 ||
           got_old_reject!==got_new_reject || got_old_ratio!==got_new_ratio ||
           got_old_corr!==got_new_corr || got_old_period!==got_new_period)
            $fatal(1,"estimator mismatch old good=%b spo2=%0d reject=%h ratio=%h corr=%0d period=%0d new good=%b spo2=%0d reject=%h ratio=%h corr=%0d period=%0d",
                got_old_good,got_old_spo2,got_old_reject,got_old_ratio,got_old_corr,got_old_period,
                got_new_good,got_new_spo2,got_new_reject,got_new_ratio,got_new_corr,got_new_period);
        $display("ESTIMATOR_EQUIVALENCE_PASS cycles=%0d good=%b spo2=%0d reject=%h",k,got_new_good,got_new_spo2,got_new_reject);
        $finish;
    end
endmodule
