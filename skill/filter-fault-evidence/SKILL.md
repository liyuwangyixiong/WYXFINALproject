---
name: filter-fault-evidence
description: Trace sensor values through freshness, quality, filtering, fault qualification and fusion, then explain alerts with verifiable evidence. Use for FPGA or embedded monitoring pipelines; not for clinical diagnosis.
---

# Filter and fault evidence chain

适用于多路传感器、工业状态量或环境监测的 RTL/嵌入式管线。目标是回答：**观测到什么、当前数值能否使用、状态为何改变、下一步该查哪层**。项目阈值、状态名称和器件数量均从目标工程读取，不套用本项目的生理阈值。

## 使用流程

1. 收集模块源码、单位与缩放、配置门限、上游事件定义、输出协议。若分析实测，附同一固件的哈希、时间戳、原始输入、滤波输出与有效位；缺任一关键证据时只做静态审查或标记“未验证”。
2. 从**物理器件**开始画事件链：事务完成、真实新样本及序号、质量窗口、可信指标、滤波握手、数据新鲜度、待确认原因、已确认故障、融合状态。不要把一次寄存器轮询当成新转换，也不要把一颗器件的多个故障原因算成多颗损坏器件。
3. 逐段检查阻断与恢复：`valid && ready` 才是消费事件；`valid=0` 时旧数据位不得当实时值；坏值不能推进滤波历史；单次毛刺或 NACK 与持续故障分开；恢复须由新的好事件支持。
4. 把器件故障、信号质量不足、编码非法、配置错误、持续越界分开解释。可信范围告警与“设备坏了”是不同命题。无效通道退出融合，保留其他通道的危险证据；“剩余通道正常”必须同时注明降级。
5. 用 [证据矩阵与记录模板](references/evidence_matrix.md) 逐条写“证据 → 数据处理 → 状态/下一步”，每条附代码位置或同固件采集记录。只给结论且无法指出证据时，结论降级为待查。

## 本工程的静态核对结果

`src/rtl/sensor_fault_monitor.sv` 将通信、无更新/冻结和质量分别计数，输出待确认与已确认原因；`src/rtl/metric_robust_smoother.sv` 只接收可信的新指标；`src/rtl/health_parallel4_top.sv` 按物理器件保留四路独立历史、以新鲜度门控输出，并把器件不可用与健康范围告警分开。这证明**源码具备相应结构**，不能替代新版 bitstream 的整板动态验收。

## 失效条件

没有可靠时基、真实新样本标识、有效位或同固件输入/输出配对时，不能量化滤波效果或故障响应时间。只有最终显示数值时，不能反推出原始质量，也不能确认器件硬件损坏。个人测试数据不得转成通用阈值。
