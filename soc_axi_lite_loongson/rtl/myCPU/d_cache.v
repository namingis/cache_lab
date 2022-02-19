module d_cache (
    input wire clk, rst,
    //mips core
    input         cpu_data_req     ,
    input         cpu_data_wr      ,
    input  [1 :0] cpu_data_size    ,
    input  [31:0] cpu_data_addr    ,
    input  [31:0] cpu_data_wdata   ,
    output [31:0] cpu_data_rdata   ,
    output        cpu_data_addr_ok ,
    output        cpu_data_data_ok ,

    //axi interface
    output         cache_data_req     ,
    output         cache_data_wr      ,
    output  [1 :0] cache_data_size    ,
    output  [31:0] cache_data_addr    ,
    output  [31:0] cache_data_wdata   ,
    input   [31:0] cache_data_rdata   ,
    input          cache_data_addr_ok ,
    input          cache_data_data_ok
);
    //Cache配置
    parameter  INDEX_WIDTH  = 10, OFFSET_WIDTH = 2;
    localparam TAG_WIDTH    = 32 - INDEX_WIDTH - OFFSET_WIDTH;
    localparam CACHE_DEEPTH = 1 << INDEX_WIDTH;
    
    //Cache存储单元
    reg                 cache_valid [CACHE_DEEPTH - 1 : 0];
    reg [TAG_WIDTH-1:0] cache_tag   [CACHE_DEEPTH - 1 : 0];
    reg [31:0]          cache_block [CACHE_DEEPTH - 1 : 0];
    reg                 cache_dirty [CACHE_DEEPTH - 1 : 0];

    //访问地址分解
    wire [OFFSET_WIDTH-1:0] offset;
    wire [INDEX_WIDTH-1:0] index;
    wire [TAG_WIDTH-1:0] tag;
    
    assign offset = cpu_data_addr[OFFSET_WIDTH - 1 : 0];
    assign index = cpu_data_addr[INDEX_WIDTH + OFFSET_WIDTH - 1 : OFFSET_WIDTH];
    assign tag = cpu_data_addr[31 : INDEX_WIDTH + OFFSET_WIDTH];

    //访问Cache line
    wire c_valid;
    wire [TAG_WIDTH-1:0] c_tag;
    wire [31:0] c_block;
    wire c_dirty;

    assign c_valid = cache_valid[index];
    assign c_tag   = cache_tag  [index];
    assign c_block = cache_block[index];
    assign c_dirty = cache_dirty[index];

    //判断是否命中
    wire hit, miss;
    assign hit = c_valid & (c_tag == tag);  //cache line的valid位为1，且tag与地�?中tag相等
    assign miss = ~hit;

    //读或�?
    wire read, write;
    assign write = cpu_data_wr;
    assign read = ~write;

    //FSM
    parameter IDLE = 2'b00, RM = 2'b01, WM = 2'b11;
    reg [1:0] state;
    always @(posedge clk) begin
        if(rst) begin
            state <= IDLE;
        end
        else begin
            case(state)
                IDLE:   state <= cpu_data_req & read & miss ? RM :
                                 cpu_data_req & read & hit  ? IDLE :
                                 cpu_data_req & write & miss & c_dirty  ? WM : IDLE;
                RM:     state <= read_finish ? IDLE : RM;
                WM:     state <= write & cache_data_data_ok ? IDLE : WM;
            endcase
        end
    end

    //读内�?
    //变量read_req, addr_rcv, read_finish用于构�?�类sram信号�?
    wire read_req;      //�?次完整的读事务，从发出读请求到结�?
    reg [1:0] rcv;       //地址接收成功(addr_ok)后到结束
    wire read_finish;   //数据接收成功(data_ok)，即读请求结�?
    always @(posedge clk) begin
        if(rst) begin
            rcv <= 2'b00;
        end
        else begin case(rcv)
            2'b00: 
                if(read_req & cache_data_addr_ok & c_dirty) begin
                    rcv <= 2'b01;
                end
                else if(read_req & cache_data_addr_ok & ~c_dirty) begin
                    rcv <= 2'b11;
                end
                else begin
                    rcv <= rcv;
                end
            2'b01:
                if(read_req & cache_data_data_ok) begin
                    rcv <= 2'b10;
                    cache_dirty[index] <= 1'b0;
                end
                else begin
                    rcv <= rcv;
                end
            2'b10:
                if(read_req & cache_data_addr_ok) begin
                    rcv <= 2'b11;
                end
                else begin
                    rcv <= rcv;
                end
            2'b11:
                if(read_req & cache_data_data_ok) begin
                    rcv <= 2'b00;
                end
                else begin
                    rcv <=rcv;
                end
        endcase
        end
        // rcv <= rst ? 1'b0 :
        //             read & cache_data_req & cache_data_addr_ok ? 1'b1 :
        //             read_finish ? 1'b0 : rcv;
    end
    assign read_req = state==RM;
    assign read_finish = read & cache_data_data_ok & (rcv[1] ^~ rcv[0]);

    //写内�?
    wire write_req;     
    reg w_rcv;      
    wire write_finish;   
    always @(posedge clk) begin
        w_rcv <= rst ? 1'b0 :
                     write & cache_data_req & cache_data_addr_ok ? 1'b1 :
                     write_finish ? 1'b0 : w_rcv;
        // w_rcv <= rst ? 1'b0 :
        //              write & cache_data_req & cache_data_addr_ok ? 1'b1 :
        //              write_finish ? 1'b0 : w_rcv;            
    end
    assign write_req = state==WM;
    assign write_finish = write & cache_data_data_ok;

    //output to mips core
    assign cpu_data_rdata   = hit ? c_block : cache_data_rdata;
    assign cpu_data_addr_ok = cpu_data_req & hit | read & cache_data_req & cache_data_addr_ok & ~c_dirty | 
                            write & cache_data_req & cache_data_data_ok | write & cpu_data_req & cpu_data_wr & ~c_dirty;
    assign cpu_data_data_ok = cpu_data_req & hit | read_finish | write & cpu_data_req & cache_data_data_ok | write &  cpu_data_req & cpu_data_wr & ~c_dirty;

    reg [TAG_WIDTH-1:0] tag_save;
    reg [INDEX_WIDTH-1:0] index_save;
    reg [31:0] write_data_save;
    reg dirty_save;
    
    //output to axi interface
    assign cache_data_req   = read_req & ~rcv[0] | write_req & ~w_rcv;
    assign cache_data_wr    = state != RM ? cpu_data_wr:
                              c_dirty ? ~cpu_data_wr : cpu_data_wr;
    assign cache_data_size  = state != RM ? 2'b10:
                              c_dirty ? 2'b10 : cpu_data_size;
    assign cache_data_addr  = state != RM ? {c_tag, index, 2'b00}: //{tag_save, index_save, 2'b00}
                              c_dirty ? {c_tag, index, 2'b00} : cpu_data_addr;
    assign cache_data_wdata = state != RM ? cache_block[index]:
                              c_dirty ? cache_block[index] : cpu_data_wdata;

    //写入Cache
    //保存地址中的tag, index，防止addr发生改变

    always @(posedge clk) begin
        tag_save   <= rst ? 0 :
                      cpu_data_req ? tag : tag_save;
        index_save <= rst ? 0 :
                      cpu_data_req ? index : index_save;
        write_data_save <= rst ? 0 :
                      cpu_data_req ? cpu_data_wdata : write_data_save;
        dirty_save <= rst ? 0 :
                      cpu_data_req ? c_dirty : write_data_save;
    end

    wire [31:0] write_cache_data;
    wire [3:0] write_mask;

    //根据地址低两位和size，生成写掩码（针对sb，sh等不是写完整�?个字的指令）�?4位对�?1个字�?4字节）中每个字的写使�?
    assign write_mask = cpu_data_size==2'b00 ?
                            (cpu_data_addr[1] ? (cpu_data_addr[0] ? 4'b1000 : 4'b0100):
                                                (cpu_data_addr[0] ? 4'b0010 : 4'b0001)) :
                            (cpu_data_size==2'b01 ? (cpu_data_addr[1] ? 4'b1100 : 4'b0011) : 4'b1111);

    //掩码的使用：位为1的代表需要更新的�?
    //位拓展：{8{1'b1}} -> 8'b11111111
    //new_data = old_data & ~mask | write_data & mask
    assign write_cache_data = cache_block[index] & ~{{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}} | 
                              cpu_data_wdata & {{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}};

    integer t;
    always @(posedge clk) begin
        if(rst) begin
            for(t=0; t<CACHE_DEEPTH; t=t+1) begin   //刚开始将Cache置为无效
                cache_valid[t] <= 0;
                cache_dirty[t] <= 0; //刚开始将cache设置为不�?
            end
        end
        else begin
            if(read_finish) begin //读缺失，访存结束�?
                cache_valid[index] <= 1'b1;             //将Cache line置为有效
                cache_tag  [index] <= tag;        //tag_save index_save 换和
                cache_block[index] <= cache_data_rdata; //写入Cache line
                cache_dirty[index] <= 1'b0;
            end
            else if(write & cpu_data_req & hit | write & cpu_data_req & miss & !c_dirty) begin   //写命中时�?要写Cache
                cache_block[index] <= cpu_data_wdata;      //写入Cache line，使用index而不是index_save
                cache_valid[index] <= 1'b1;             //将Cache line置为有效
                cache_tag  [index] <= tag;
                cache_dirty[index] <= 1'b1;
            end
            else if(write_finish) begin
                cache_valid[index] <= 1'b1;             //将Cache line置为有效
                cache_tag  [index] <= tag;
                cache_block[index] <= cpu_data_wdata; //写入Cache line //write_data_save 换和
                cache_dirty[index] <= 1'b1 ;
            end
        end
    end
endmodule