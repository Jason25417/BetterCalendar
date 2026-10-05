# 0.65.4 (161) Mac 多目录状态采集

2026-10-05。Jason选择覆盖所有常用App类别，文件范围由开发侧尽可能全面选择。

本批Mac新增最多12个目录及子目录的元数据采集，兼容160单目录bookmark；目录权限仍通过用户选择授予。建议学习、Developer、Documents、Desktop、Downloads。独立actor按目录2000项/0.4秒预算分轮继续，不读正文；排除隐藏项、依赖/缓存/包目录、常见凭据与符号链接。

files.activity v2包含目录覆盖状态、权限失败数、最多35件最新元数据及稳定路径摘要ID；长路径截短显示仍通过ID区别。遍历不完整保留已知线索，只有完整且可读的扫描周期才能清除消失文件。新快照独立于SwiftData/CloudKit旧模型，没有schema部署。

## 验证

- Mac新增4项Swift Testing全部通过。首次测试发现对符号链接调用skipDescendants会跳过兄弟目录；改为直接跳过链接后回归通过。
- iOS Simulator条件编译通过。
- 五个建议目录的CLI元数据扫描：三轮约0.61/0.47/0.27秒，35个最新候选；大目录partial-budget继续下一轮，不伪装完整。此CLI验证没有上传用户文件线索。
- Mac Release archive、上传、ASC分发状态：进行中，完成后写回真实回执。

## 仍需实际设备验收

iPhone保留已可用的0.65.3 (160)，本批只有Mac采集变化，不重复发布手机二进制。现有正式插件订阅/合成事件/Dot自动读取与ack已通过，服务16:25 UTC仍只有合成来源。尚需Mac/iPhone配置与OS权限；iPhone连接解锁后整理已安装App，逐个或按组配置个人自动化。全局App使用流不可因用户授权而假设存在。

独立云端一分钟clock源码已准备，但Cloudflare当前未登录，尚未部署。Mac在线一分钟flush/手机事件可用，设备休眠后定时flush仍待云端账号。Computer Use拒绝访问BetterCalendar，需要实际应用访问权限或由用户手动设置。
