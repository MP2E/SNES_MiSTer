//
// sdram.v
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram
(

	// interface to the MT48LC16M16 chip
	inout  reg [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output reg        SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CKE,

	// cpu/chipset interface
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz

	input      [24:0] addr,
	input             rd,
	input             wr,
	input             word,
	input      [15:0] din,
	output     [15:0] dout,
	output reg        busy
);

assign SDRAM_CKE = ~init;

localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles@85MHz
localparam BURST_LENGTH   = 3'd0; // 0=1, 1=2, 2=4, 3=8, 7=full page
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2; // 2/3 allowed
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

localparam STATE_IDLE  = 3'd0;             // state to check the requests
localparam STATE_START = STATE_IDLE+1'd1;  // state in which a new command is started
localparam STATE_CONT  = STATE_START+RASCAS_DELAY;
localparam STATE_READY = STATE_CONT+CAS_LATENCY+1'd1;
localparam STATE_LAST  = STATE_READY;      // last state in cycle

reg  [2:0] state;
reg [24:0] a;
reg [15:0] data;
reg        we;
reg        ds;
reg        ram_req=0;
wire       ram_req_test = (we || (a[24:1] != addr[24:1]));
reg [15:0] last_data;

// access manager
always @(posedge clk) begin
	reg old_ref;
	reg old_rd,old_wr;

	old_rd <= old_rd & rd;
	old_wr <= old_wr & wr;

	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		if((~old_rd & rd) | (~old_wr & wr)) begin
			old_rd <= rd;
			old_wr <= wr;
			we <= wr;
			ds <= word;
			busy <= 1;
			state <= STATE_START;
		end
	end
	
	if(state == STATE_START && busy) begin
		a <= addr;
		data <= word ? din : {din[7:0],din[7:0]};
		ram_req <= ram_req_test;
	end

	if(state == STATE_READY && busy) begin
		ram_req <= 0;
		we <= 0;
		busy <= 0;
		if(ram_req) begin
			if(we) begin
				a <= '1;
			end
			else begin
				last_data <= SDRAM_DQ;
			end
		end
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
	end
end

assign dout = ram_req ? ((~ds & a[0]) ? {SDRAM_DQ[7:0], SDRAM_DQ[15:8]}  : SDRAM_DQ) :
								((~ds & a[0]) ? {last_data[7:0],last_data[15:8]} : last_data);

localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

// initialization 
reg [1:0] mode;
reg [4:0] reset=5'h1f;
always @(posedge clk) begin
	reg init_old=0;
	init_old <= init;

	if(init_old & ~init) reset <= 5'h1f;
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

localparam CMD_INHIBIT         = 4'b1111;
localparam CMD_NOP             = 4'b0111;
localparam CMD_ACTIVE          = 4'b0011;
localparam CMD_READ            = 4'b0101;
localparam CMD_WRITE           = 4'b0100;
localparam CMD_BURST_TERMINATE = 4'b0110;
localparam CMD_PRECHARGE       = 4'b0010;
localparam CMD_AUTO_REFRESH    = 4'b0001;
localparam CMD_LOAD_MODE       = 4'b0000;

// SDRAM state machines
always @(posedge clk) begin
	casex({ram_req,we,mode,state})
		{2'bXX, MODE_NORMAL, STATE_START}: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= ram_req_test ? CMD_ACTIVE : CMD_AUTO_REFRESH;
		{2'b11, MODE_NORMAL, STATE_CONT }: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE;
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_INHIBIT;
	endcase

	casex({mode,state})
		{MODE_NORMAL, STATE_START}: SDRAM_A <= addr[13:1];
		{MODE_NORMAL, STATE_CONT }: SDRAM_A <= {4'b0010, a[22:14]};

		// init
		{   MODE_LDM, STATE_START}: SDRAM_A <= MODE;
		{   MODE_PRE, STATE_START}: SDRAM_A <= 13'b0010000000000;

		                   default: SDRAM_A <= 13'b0000000000000;
	endcase

	if(state == STATE_START) begin
		SDRAM_BA <= (mode == MODE_NORMAL) ? addr[24:23] : 2'b00;
		{SDRAM_DQMH,SDRAM_DQML} <= (~we | ds) ? 2'b00 : {~addr[0], addr[0]};
	end

	SDRAM_DQ <= 'Z;
	if((state >= (STATE_CONT-1) && state <= (STATE_CONT+1)) && we) SDRAM_DQ <= data;
end

endmodule
