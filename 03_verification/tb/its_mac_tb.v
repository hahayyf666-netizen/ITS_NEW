`timescale 1ns / 1ps          // 仿真时间单位 = 1ns，精度 = 1ps

module its_mac_tb;

    // ============ 信号声明 ============
    reg         clk;
    reg         rst_n;
    reg         en;
    reg         clr;
    reg  [15:0] a;
    reg  [15:0] b;
    wire [39:0] result;
    wire        valid;

    // ============ 实例化被测模块（DUT）============
    its_mac u_mac (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .clr   (clr),
        .a     (a),
        .b     (b),
        .result(result),
        .valid (valid)
    );

    // ============ 时钟生成 ============
    // 500MHz → 周期 = 2ns → 半周期 = 1ns
    initial clk = 0;
    always #1 clk = ~clk;       // 每 1ns 翻转一次

    // ============ 测试流程 ============
    initial begin
        // 1. 复位
        rst_n = 0;
        en    = 0;
        clr   = 0;
        a     = 16'd0;
        b     = 16'd0;
        #5;                      // 等 5ns，确保复位完成
        rst_n = 1;
        #2;                      // 再等 2ns

        // 2. 第 1 拍：清零 + 送入第一组数据（3×5）
        //    这一拍做的事：
        //      第1级：a×b = 3×5 = 15，锁进 product 寄存器
        //      第2级：clr=1 → 累加器清零
        @(posedge clk);          // 等下一个时钟上升沿
        en  = 1;
        clr = 1;
        a   = 16'd3;
        b   = 16'd5;

        // 3. 第 2 拍：送入第二组数据（7×2），关清零
        //    这一拍做的事：
        //      第1级：a×b = 7×2 = 14，锁进 product
        //      第2级：上一拍的 product=15 累加到 result
        //             result = 0 + 15 = 15
        @(posedge clk);
        clr = 0;
        a   = 16'd7;
        b   = 16'd2;

        // 4. 第 3 拍：没有新数据，关使能
        //    这一拍做的事：
        //      第1级：en=0，不干活
        //      第2级：上一拍的 product=14 累加到 result
        //             result = 15 + 14 = 29
        @(posedge clk);
        en  = 0;

        // 5. 再等几拍，看波形
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);

        // 6. 结束仿真
        $display("Simulation finished.");
        $finish;
    end

    // ============ 监控打印（看结果）============
    always @(posedge clk) begin
        $display("t=%0t | en=%b clr=%b a=%d b=%d | result=%d valid=%b",
                 $time, en, clr, a, b, result, valid);
    end

endmodule
