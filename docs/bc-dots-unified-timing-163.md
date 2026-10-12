# BC × Dots 统一计时：0.65.6 / 163

2026-10-12，America/New_York。此批是在长期事项/旧历史迁移之前，先让新增计时共用同一个保存入口。

## 已实现

- Dots 的 task_command 与登记设备的 BC 按钮都写入同一 D1 sessions / commands。计时记录、revision、时间戳和幂等回执只有一份；来源新事件为 bc:tasks，旧 dot:tasks 历史未重写。
- 新设备请求携带原有 private Site 凭据与设备令牌；只有已有 user.context 范围的交互设备可读/操作计时。独立时钟、合成探针不能通过此接口控制任务；没有扩大网页共享。
- 新执行面板、Mac静态菜单栏标题、iPhone Live Activity 投影同一状态；初次同步后才可开始操作。暂停不增长，结束计时不标记事项完成，不在另一端创建第二条 SwiftData 实际记录。
- 操作先写本机独立队列再请求保存；丢失响应和重启用原 commandId 重试。HTTP409保留失败请求并重读，不覆盖另一端新版本。离线待同步时不声称云端已执行，待确认期间不连续提交更多控制命令。
- 设备显示以请求时间中点和服务端 readAt 对齐，按钮时间也校正到同一服务器时间轴；网络往返仍带来估计误差，不把显示相同当作零延迟。
- 活动/有待传操作时约5秒查询，空闲约15秒；超过60秒未收到新结果明确显示旧状态。配置仍在时可显示计时，停止传感器采集不自动结束任务。
- Mac把新确认状态投影到既有 FocusRunState 以触发iPhone静默推送；iPhone接收后只读刷新BC，不重发投影。旧进行中任务/待恢复快照保留原位，先沿用旧执行入口，不自动迁移、结束或重建历史。
- Calendar/Reminders同步读取移到独立actor，EKEventStore懒加载；提醒回调nil不再当作成功空列表；按字节/条数限制并明示遗漏。
- 完整档案另保留 bridge/outbox、task-commands 原始字节，仅供核对；隔离恢复不重放它们，也不导入接入密钥或设备身份。新档案权限600。
- MCP可先includeValues=false查看摘要，再按sourceKeys读所需正文；read_changes响应有界，可指定throughId只读完本批。全部有效变化仍交Dots判断，未增加语义过滤。

## 验证与发布证据

macOS 255/255通过（xcresult正式汇总），iOS Simulator编译通过；SQLite核心17/17，TS与服务build通过。新增验证包括丢失回执重试、重启、版本冲突、文件保存失败、坏队列原位保留、计时/暂停投影、时钟偏差校正、按钮不创建第二份本地历史、外部数据修改可见和MCP分页/摘要语义。

两次全量门控暴露旧parser测试的MainActor fixture构造占用模拟网络时间窗；预先构造不可变fixture后保留原时间窗和全部断言，全量通过。没有修改生产解析策略。

私有云端版本11已部署成功，源commit78cbfbdd6ee5dd69ef4c8d55c5af021a4fe5ce4c。D1只追加两个可空元数据列；没有新的SwiftData/CloudKit模型或字段。正式MCP摘要读取返回21来源、不含正文，随后单来源正文读取成功。

163双端稳定Xcode串行归档/上传成功，ASC回读确认两个构建均VALID、IN_BETA_TESTING，中文测试说明一致。iOS构建5e353656-c99a-407e-b5bc-f834fe0f6a40；Mac构建74f4c1dc-faad-43d3-989d-bbea2ecfa445。上传状态/tmp/bc-release-163/status.json，校验工具/tmp/bc-release-163-asc.py。源码79f31a6已推送。

Mac已通过TestFlight安装163，原生界面显示0.65.6(163)，设置采集开关/登录启动均on，12:12–12:13保存持续更新。选择指定build时TestFlight临时关闭自动更新，已恢复on。升级后再次导出432条旧记录并在隔离空库恢复通过：字段、关系、照片一致，日用库未写入。档案/Users/jasontu/Downloads/BetterCalendar-Data/snapshot-03B49607-F442-4A15-99E0-5DA0B3F10565.json，10,068,307字节、权限600；没有上传私人档案。

后续云端版本12私有部署成功：e981c5c761ad291e122ce6fdbe991d3f00d84f07，新增原始操作回执查询和计时历史分页，不更改数据库表或原记录。SQLite20/20、TS/build通过；正式MCP计时历史查询返回hasMore/nextCursor等新字段成功，当前无计时记录。Dots于16:16:58 UTC发现并实际调用read_task_commands(limit=1)成功，返回commands=[]、hasMore=false；当前没有保存回执，不创建虚假任务。Edge页面证据/private/tmp/bc-dots-v12-diagnostic-result.png。

## 尚未验收与限制

- 双端真实按钮/对话计时链路、实际传输延迟、锁屏显示仍需安装163后验证；单测不能替代真机。
- iOS后台由系统调度，首次在后台创建Live Activity不能靠定时器保证。此版利用既有推送与常驻Mac转发；Mac完全关闭时，服务器保存仍可靠，但不能承诺手机立刻出现新活动。专用APNs/push-to-start链路未完成。
- 当前统一通道先支持轻计时；旧番茄运行态不自动转换。旧进行中记录仍用旧入口，尚未形成完整迁移方案。
- 旧70条会话及其它SwiftData资料已随432条真实档案在隔离空库恢复验证；尚未迁移到新D1会话。长期事项/机会/愿望编辑MCP、30天回收站、完整跨版本与多端实测仍未完成。
- Dots当前状态工具可用；事件处理仍可能排队数分钟甚至更久。摘要与固定批次终点降低重复读取，不证明平台调度延迟已经解决。
- 手机镜像曾成功连接并显示真实主屏；开发设备列表只有模拟器。不能据镜像可见认定App/Focus快捷指令自动化已配置。
- 当前完全访问只解决本地开发执行权限。手机镜像再次连接后出现系统画面捕获失败，未验手机安装163；iPhone各来源最后更新仍约11:17，App/Focus未接入，Mac仅选择1个文件目录。不能因此声称全部数据源权限/后台采集完成。
