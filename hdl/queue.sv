/****************************************************************
 * queue.sv - queue structure for storing memory requests
 *
 * Authors       : Viraj Khatri (vk5@pdx.edu)
 *               : Varden Prabahr (nagavar2@pdx.edu)
 *               : Sai Krishnan (saikris2@pdx.edu)
 *               : Chirag Chaudhari (chirpdx@pdx.edu)
 * Last Modified : 16 November, 2021
 *
 * Description   :
 * -----------
 * takes input from parser, and stores in queue
 ****************************************************************/

import global_defs::*;

module queue
(
	// inputs
	input  logic               clk, rst_n,

	// inputs from parser
	input  parser_out_struct_t in,              // has op_ready_s, opcode, address and time_cpu

	// outputs to parser
	output logic               pending_request, // flag - request is not acknowledged yet
	output logic               queue_full,      // flag - queue is full

	// outputs
	output parser_out_struct_t out,                   // output to next module (memory controller / DRAM?)
	output parser_out_struct_t queue[$:QUEUE_SIZE-1], // queue to store many memory requests
	output age_counter_t       age[$:QUEUE_SIZE-1],
	output int_t               queue_time             // display what time is queue currently at (int)
);


int_t curr_time;
assign queue_time = curr_time;

wire output_allowed;
logic half_clk;
parser_out_struct_t out_buffer;

dram_output_t out_dram;

// array for tracking bank statuses
bank_status_t bank_status[2**BG_WIDTH][2**BANK_WIDTH];

// tracking what operation in the bank_status array was last done
// to decide what t_R/C/W delay to follow
prev_operation_t previous_operation;

logic output_allowed_normal;

int unsigned dram_file;
string dram_filename = "dram";

initial begin : dram_file_open
	dram_file = $fopen(dram_filename, "w");
	if (dram_file == 0) begin
		$fatal("Could not open dram output file (%s)", dram_filename);
	end
end

/***************************
 * flags to send to parser *
 ***************************/
always_comb begin : queue_flag
	if (queue.size() == QUEUE_SIZE) queue_full = 1'b1;
	else queue_full = 1'b0;
end : queue_flag

/*************************
 * print on queue output *
 *************************/
function automatic queue_output_display(parser_out_struct_t queue_item);
	$display("%t : OUTPUT DRAM : element:'{time_cpu:%0t, opcode:%p, address:0x%h}' : curr_time=%0d",
				 $time,
				 queue_item.time_cpu,
				 queue_item.opcode,
				 queue_item.address,
				 curr_time);

	// determining bank group, bank, column, row
	$display("%t :             : bank group=%0d, bank=%0d, column=%0d, row=%0d",
	          $time,
	          ((bank_group_mask & queue_item.address) >> BG_OFFSET),
	          ((bank_mask       & queue_item.address) >> BANK_OFFSET),
	          ((column_mask     & queue_item.address) >> COLUMN_OFFSET),
	          ((row_mask        & queue_item.address) >> ROW_OFFSET));

endfunction

/******************
 * dataflow block *
 ******************/
always_ff@(posedge clk or negedge rst_n) begin : parser_in
	if ($test$plusargs("per_clock"))
		$display("%t :    START    : full,pend=%b,%b  curr_time=%0d : in=%p", $time, queue_full, pending_request, curr_time, in);

	if (!rst_n) begin
		queue.delete();
		curr_time <= 0;
		pending_request <= 1'b0;
		out_dram.address <= '0;
		out_dram.opcode <= RD; // 0 on reset
		bank_status <= '{default: '0};
		output_allowed_normal <= 0;
	end

	else begin

		// output from queue
		decide_output_buffer();
		bank_status_checks();
		bank_status_and_output_update();

		// taking input from parser
		if (in.op_ready_s) begin

			if (queue.size() == 0) begin
				curr_time <= in.time_cpu; // time skip in empty queue
				if ($test$plusargs("debug_queue")) $display("%t : QUEUE_EMPTY : queue is empty, advancting time to %0t",$time,in.time_cpu);
			end

			if ((queue.size() < QUEUE_SIZE && curr_time >= in.time_cpu) || queue.size() == 0) begin
				queue.push_front(in);
				age.push_front(0);
				pending_request <= 1'b0;


				if ($test$plusargs("debug_queue")) begin
					$display("%t :   INSERT    : element:'{time_cpu:%0t, opcode:%p, address:0x%h}' : curr_time=%0d",
					          $time,
					          in.time_cpu,
					          in.opcode,
					          in.address,
					          curr_time);
					$display("%t :             : queue has %0d elements now :   '{",$time, queue.size());
					for (int j=0; j < queue.size(); j++) begin
						$display("#                                                              '{time_cpu:%0t, opcode:%p, address:0x%h}' '{age:%d}',",
						           queue[j].time_cpu,
						           queue[j].opcode,
						           queue[j].address,
						           age[j]);
					end
					$display("#                                                             }'");
				end
			end else begin
				pending_request <= 1'b1;
			end
		end
	end
end : parser_in

/*******************
 * aging all queue *
 *******************/
always_ff@(posedge clk) begin : queue_age
	curr_time++;
	for (int i=0; i<queue.size(); i++) begin
		age[i]++;
	end
end : queue_age

/**********************************
 * Issuing refresh after T_REFI   *
 * And blocking outputs for T_RFC *
 **********************************/
parameter REFI_COUNTER_SIZE = $clog2(T_REFI);
logic [REFI_COUNTER_SIZE-1:0] refi_counter;
parameter RFC_COUNTER_SIZE = $clog2(T_RFC);
logic [RFC_COUNTER_SIZE-1:0] rfc_counter;

logic out_allowed_refresh;
// this should overwrite other signals to stop output on low only
// as if refresh command is issued, DRAM cannot be accessed
assign (strong0, weak1) output_allowed = out_allowed_refresh;

always_ff@(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		refi_counter <= T_REFI;
		rfc_counter <= T_RFC;
	end

	else begin
		if (refi_counter == '0) begin // t_refi is done, issue a refresh command now

			if (rfc_counter == '0) begin
				if ($test$plusargs("debug_dram"))
					$display("%t :  REFRESHED  : outgoing DRAM commands resumed : curr_time = %0d", $time, curr_time);
				refi_counter <= T_REFI;
				rfc_counter <= T_RFC;
				out_allowed_refresh <= 1;
			end
			else begin
				if ($test$plusargs("debug_dram") && rfc_counter == T_RFC)
					$display("%t :   REFRESH   : outgoing DRAM commands halted : curr_time = %0d", $time, curr_time);
				out_allowed_refresh <= 0;
				rfc_counter <= rfc_counter-1;

				dram_file_print('0, REF);
			end
		end

		else begin
			out_allowed_refresh <= 1;
			refi_counter <= refi_counter-1;
		end
	end
end

/*************************************************
 * Outputting requests to DRAM on half frequency *
 *************************************************/
always_ff@(posedge clk or negedge rst_n) begin
	if (!rst_n) half_clk = 0;
	else half_clk <= ~half_clk;
end

// this should be able to change when refresh is not holding down at 0
// thus pull0, weaker than strong0, allows refresh to overwrite
// thus pull1, stronger than weak1, allows correct output to owerwrite
assign (pull0, pull1) output_allowed = output_allowed_normal;

always_ff@(posedge half_clk) begin
	
	//if ($test$plusargs("debug_dram")) $display("%0t - output_allowed(ref, norm)=%b(%b,%b)", $time, output_allowed, out_allowed_refresh, output_allowed_normal);

	if (output_allowed) begin
		out <= out_buffer;
		output_allowed_normal <= 0;


		if ($test$plusargs("debug_dram"))
			$display("%t : out_dram=%p", $time, out_dram);

		dram_file_print(out_dram.address, out_dram.opcode);

		if ($test$plusargs("debug_queue"))
			queue_output_display(out_buffer); // age popping last element, so display that

		if (out_dram.opcode == RD || out_dram.opcode == WR) begin // full command outputted, pop from queue now
			queue.pop_back();
			age.pop_back();
		end

		if ($test$plusargs("debug_queue")) begin
			$display("%t :             : queue has %0d elements now :   '{", $time, queue.size());
			for (int j=0; j < queue.size(); j++) begin
				$display("#                                                              '{time_cpu:%0t, opcode:%p, address:0x%h}' '{age:%d}',",
							  queue[j].time_cpu,
							  queue[j].opcode,
							  queue[j].address,
							  age[j]);
			end
			$display("#                                                             }'");
		end
	end
end

/*************************
 * printing to dram file *
 *************************/
function automatic dram_file_print(logic [ADDRESS_WIDTH-1:0] address, DRAM_commands_t opcode);

	begin
		// temporary variables, limiting scope to this function
		logic [BG_WIDTH-1:0] bank_group;
		logic [BANK_WIDTH-1:0] bank;
		logic [ROW_WIDTH-1:0] row;
		logic [COLUMN_WIDTH-1:0] column;
		bank_group = (bank_group_mask & address) >> BG_OFFSET;
		bank       = (bank_mask & address) >> BANK_OFFSET;
		row        = (row_mask & address) >> ROW_OFFSET;
		column     = (column_mask & address) >> COLUMN_OFFSET;

		$fwrite(dram_file, "%0t %p", curr_time, opcode);
		unique case(opcode)
			RD: begin
				$fwrite(dram_file, " %0d %0d %0d", bank_group, bank, column);
			end
			WR: begin
				$fwrite(dram_file, " %0d %0d %0d", bank_group, bank, column);
			end
			ACT: begin
				$fwrite(dram_file, " %0d %0d %0d", bank_group, bank, row);
			end
			PRE: begin
				$fwrite(dram_file, " %0d %0d", bank_group, bank);
			end
			REF: begin
			end
		endcase

		$fwrite(dram_file, "\n");
	end

endfunction

/****************************************************
 * Update the bank_status and output file if we can *
 ****************************************************/
function automatic bank_status_and_output_update();
		// decrement all countdown in bank_status
		for (int i=0; i<(2**BG_WIDTH); i++) begin
			for (int j=0; j<(2**BANK_WIDTH); j++) begin
				if (bank_status[i][j].curr_operation != NO_OP && bank_status[i][j].countdown != 0) begin
					bank_status[i][j].countdown <= bank_status[i][j].countdown - 1'b1; // count down if a valid operation has a non-zero counter
				end
			end
		end

		// check if we can output, and call dram_file_write if we can
		for (int i=0; i<(2**BG_WIDTH); i++) begin
			for (int j=0; j<(2**BANK_WIDTH); j++) begin
				if (bank_status[i][j].curr_operation != NO_OP && bank_status[i][j].countdown == 0) begin
					// curr_operation is not NO_OP and timer is 0, so no timing can be violated, let's output now

					if($test$plusargs("debug_dram")) $display("%t : bank_status[%0d][%0d] - %p", $time, i, j, bank_status[i][j]);



					// because we are outputting currently outgoing op is prev_op for following cycles
					previous_operation.bank_group <= i;
					previous_operation.bank <= j;

					unique case(bank_status[i][j].curr_operation)
						NO_OP: begin
						end// not possible
						READ: begin
							out_dram.address <= bank_status[i][j].address;
							out_dram.opcode <= RD;
							bank_status[i][j].curr_operation <= NO_OP;
							bank_status[i][j].countdown <= T_CAS+T_BURST;
							previous_operation.wr <= RD;

							output_allowed_normal <= 1; // new output on dram
						end
						WRITE: begin
							out_dram.address <= bank_status[i][j].address;
							out_dram.opcode <= WR;
							bank_status[i][j].curr_operation <= NO_OP;
							bank_status[i][j].countdown <= T_CAS+T_BURST;
							previous_operation.wr <= WR;

							output_allowed_normal <= 1; // new output on dram
						end
						ACT_READ: begin
							out_dram.address <= bank_status[i][j].address;
							out_dram.opcode <= ACT;
							bank_status[i][j].curr_operation <= operations_to_do_in_order_t'(1); // gotta typecast for READ command
							bank_status[i][j].countdown <= T_RCD;

							output_allowed_normal <= 1; // new output on dram
						end
						PRE_ACT_READ: begin
							out_dram.address <= bank_status[i][j].address;
							out_dram.opcode <= PRE;
							bank_status[i][j].curr_operation <= ACT_READ;
							bank_status[i][j].countdown <= T_RP;

							output_allowed_normal <= 1; // new output on dram
						end
						TR_L_PRE_ACT_READ: begin
							// nothing to output
							bank_status[i][j].curr_operation <= PRE_ACT_READ;
							bank_status[i][j].countdown <= T_RRD_L;
						end
						TR_S_PRE_ACT_READ: begin
							// nothing to output
							bank_status[i][j].curr_operation <= PRE_ACT_READ;
							bank_status[i][j].countdown <= T_RRD_S;
						end
						TC_L_READ: begin
							// nothing to output
							bank_status[i][j].curr_operation <= operations_to_do_in_order_t'(1); // gotta typecast for READ command
							bank_status[i][j].countdown <= T_CCD_L;
						end
						TC_S_READ: begin
							// nothing to output
							bank_status[i][j].curr_operation <= operations_to_do_in_order_t'(1); // gotta typecast for READ command
							bank_status[i][j].countdown <= T_CCD_S;
						end
					endcase
				end
			end
		end

		//if($test$plusargs("debug_dram")) $display("%t : %p", $time, bank_status);

endfunction

/********************************************************
 * Check if out_buffer can be inserted into bank_status *
 *   -- All commands in bank_status.curr_operations are *
 *      commands that are currently being executed for  *
 *      that bank                                       *
 ********************************************************/
function automatic bank_status_checks();
	begin


		logic [BG_WIDTH-1:0] bank_group;
		logic [BANK_WIDTH-1:0] bank;
		logic [ROW_WIDTH-1:0] row;
		logic [COLUMN_WIDTH-1:0] column;
		bank_group = (bank_group_mask & out_buffer.address) >> BG_OFFSET;
		bank       = (bank_mask & out_buffer.address) >> BANK_OFFSET;
		row        = (row_mask & out_buffer.address) >> ROW_OFFSET;
		column     = (column_mask & out_buffer.address) >> COLUMN_OFFSET;

		// for now having non-scheduled memory access, no need to check
		// curr_operation, just insert

		if (bank_status[bank_group][bank].curr_operation == NO_OP) begin // can insert as prev command is done

			bank_status[bank_group][bank].address <= out_buffer.address;

			if ($test$plusargs("debug_dram")) $display("%t : NO_OP found in (%0d,%0d = {%p}), inserting %p",
			                                            $time, bank_group, bank, bank_status[bank_group][bank], out_buffer);

			if (bank_status[bank_group][bank].curr_row == row) begin // currently activated row is referenced again, only need to read
				//if (out_buffer.opcode == DATA_READ || out_buffer.opcode == OPCODE_FETCH) begin

					if ($test$plusargs("debug_dram")) $display("%t : current row is correct (%0d,%0d) (%0d,%0d)",
						$time, bank_status[bank_group][bank].curr_row, row, bank_group ,previous_operation.bank_group);

					if (bank_group == previous_operation.bank_group) begin
						bank_status[bank_group][bank].curr_operation <= TC_L_READ; // same bg, tc_l penalty
					end else begin
						bank_status[bank_group][bank].curr_operation <= TC_S_READ; // different bg, tc_s penalty
					end

				//end
			end

			else begin // currently active row is not referenced this time, neet to precharge activate and read
				//if (out_buffer.opcode == DATA_READ || out_buffer.opcode == OPCODE_FETCH) begin

					if ($test$plusargs("debug_dram")) $display("%t : current row is wrong", $time);
					if (bank_group == previous_operation.bank_group) begin
						bank_status[bank_group][bank].curr_operation <= TR_L_PRE_ACT_READ; // same bg, tr_l penalty
					end else begin
						bank_status[bank_group][bank].curr_operation <= TR_S_PRE_ACT_READ; // different bg, tr_s penalty
					end

				//end
			end

			//if($test$plusargs("debug_dram")) $display("%t : %p", $time, bank_status);

		end
	end

endfunction

/*****************************
 * Out Buffer decision block *
 *****************************/
function automatic decide_output_buffer();

	out_buffer <= queue[$]; // fifo without any checks for now

	// forcing age pop on 100+ CPU_clock old entries
	if (age[$] >= 100) begin
		out_buffer <= queue[$]; // overwrites decisions to provide minimum QOS of 100 cycles
	end

endfunction


endmodule : queue
