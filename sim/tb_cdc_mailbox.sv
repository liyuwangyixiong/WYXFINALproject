`timescale 1ns/1ps
module tb_cdc_mailbox;
reg sclk=0,dclk=0,srst_n=0,drst_n=0,s_valid=0;
reg [35:0] s_data=0;
wire s_overflow,d_valid;
wire [35:0] d_data;
integer received=0,errors=0,overflows=0;
always #20 sclk=~sclk;
always #5 dclk=~dclk;
wyx_cdc_mailbox #(.WIDTH(36)) dut(
 .sclk(sclk),.srst_n(srst_n),.s_valid(s_valid),.s_data(s_data),.s_overflow(s_overflow),
 .dclk(dclk),.drst_n(drst_n),.d_valid(d_valid),.d_data(d_data));
always @(posedge dclk) if(d_valid) begin
 if(d_data!==received+1) begin $display("BAD_DATA expected=%0d got=%0d",received+1,d_data);errors=errors+1;end
 received=received+1;
end
always @(posedge sclk) if(s_overflow) overflows=overflows+1;
task send(input integer word);
 begin
  @(negedge sclk);s_data=word;s_valid=1;
  @(negedge sclk);s_valid=0;
 end
endtask
integer i;
initial begin
 repeat(5) @(negedge sclk);
 srst_n=1;drst_n=1;
 for(i=1;i<=20;i=i+1) begin
  send(i);
  repeat(15) @(negedge sclk);
 end
 repeat(10) @(negedge sclk);
 if(received!=20 || errors!=0 || overflows!=0) $fatal(1,"MAILBOX_FAIL received=%0d errors=%0d overflows=%0d",received,errors,overflows);
 $display("MAILBOX_PASS received=%0d",received);
 $finish;
end
endmodule
