# 个人状态接入验收（当前 162；下文保留历史回执）

2026-10-05。此表区分代码验证与真实使用，不把编译或上传当作采集成功。

## 已验证

- [x] 私有服务正式部署成功，保留owner-private访问。
- [x] 合成观察正式上传被接受，分钟批次生成；此时activeSubscriptions=0，不是Dot处理回执。
- [x] SQLite核心测试5/5：重复/乱序、计时重试/暂停、过期恢复、签名回调重试、纠正保留历史；Worker支持manual并拒绝DNS/receiver的3xx跳转。
- [x] TypeScript检查和Worker构建。
- [x] Mac项目238项单测通过；测试宿主不读Keychain/不启动采集器/不上传。
- [x] iOS Simulator build成功（161源码条件编译也通过）。
- [x] Mac文件采集4项新测试：递归与排除/符号链接、重叠去重与新旧排序、预算/无权限/输出截断、跨轮继续与完整扫描后的删除。
- [x] 五个建议目录真实元数据扫描性能验证：三轮各约0.27–0.61秒；仅测试CLI，不是App采集或Dot的真实设备回执。
- [x] Mac/iPhone 0.65.3 (160) 均VALID、IN_BETA_TESTING，中文测试说明已保存。
- [x] Mac多目录更新0.65.4 (161)已VALID、IN_BETA_TESTING，中文测试说明写入后读回确认。
- [x] 用户安装插件后，Codex正式调用read_instructions/read_connection_status/read_current_state成功（15:47 UTC）；只有过期合成状态，未收到真实设备观察。

## 真实设备与Dot

- [x] 同一账户连接「个人状态接入」，Dot读取约定/连接状态，Codex正式插件读取成功。
- [x] Dot订阅state.minute_changed；挑战验证成功，服务端有效订阅已保存（16:07:59 UTC）。
- [ ] refreshBefore自动续约正常；当前有效期至2026-10-12 16:07:59 UTC。
- [x] 合成批次minute_29853609经正式订阅送达，16:09:28 UTC回调接收成功，attempts=1；这不是分析完成回执。
- [x] 同一自动事件触发Dot依次read_instructions、read_current_state、read_changes，再acknowledge_batch；16:10:36 UTC持久化处理回执。单次从批次生成到接收约1.7秒，到理解完成约70秒，不保证每次一分钟内完成。
- [x] iPhone网页登记后配置生效，真实健康/位置/运动/日历/提醒/家居来源到达。
- [ ] Mac配置与目录权限真实生效；不能把手机通过当作Mac通过。
- [ ] Mac多选目录授权后，files.activity v2真实数据到达；扫描不完整不得推断未活动。
- [ ] mac.activity真实观察到达；切App/进入idle的发生时间和收到时间能对齐。
- [ ] 每个有变化的分钟收到批次；同一批次重试不重复记账；Dot完成处理后出现acknowledge_batch。
- [x] iPhone睡眠/步数/静息心率/锻炼的真实结果已收到。
- [ ] 空样本/拒绝读取情况下保持未知；成功后的health.status错误清理已修复源码，当前160手机尚不包含此修复。
- [ ] 后台位置与HealthKit实测更新延迟、电量、锁屏、重启、离线补传。
- [ ] Home传感器分区实测：桌/床位置变动确认映射，离线/无中枢不伪装实时。
- [ ] 每台iPhone快捷指令App/Focus个人自动化实际触发。
- [ ] 对Dot说开始→暂停→继续→结束：工具保存成功后确认，暂停不累计，两端不重复计时。
- [ ] 告诉Dot纠正某推断后，当前解释更新，原观察仍保留。
- [ ] 用户问接下来做什么时，Dot读取最新状态、日程约束与候选，给当前可执行动作。

## 必须保留的限制

iOS后台不是分钟级定时器。独立云端分钟Worker已部署且连续三次scheduled成功，Mac关闭采集时也完成独立转发；分钟flush还保留在线Mac循环/手机事件。云端无法采集离线设备的新数据，读状态时按expiresAt即时标记stale；模型处理不保证一分钟内完成。旧BetterCalendar数据库模型未改变，无新CloudKit schema部署。

## 真机与诊断回执：2026-10-05 22:44 EDT

iPhone真实来源到达，两个分钟批次均经签名回调接收并由Dot确认处理：第一批约89秒，第二批约161秒。设备→服务→Dot已实测，不能承诺模型每批一分钟内处理完。记录中未保存个人观察内容。Mac/独立云端定时器仍待验收。

Computer Use浏览器操作可用；Computer History工具state=stopped，最新事件文件最后修改为本日11:40 EDT。观察规则默认observe且无例外。运行停止不能证明用户未打开开关；Codex自身设置UI受Computer Use保护，不能自行点开检查。安装版BetterCalendar的原生应用访问当前超时，不再按此前错误结果笼统要求全局授权。

Cloudflare网页显示原先Apple账号的已保存登录profile，但当前为登录页；Wrangler未认证。现有账号可继续使用，账号存在与本机登录是不同状态，未实际部署clock。

发现health.status初次失败后未在成功查询时恢复；源码增加queries-completed回执，仍不把空样本视为授权或无活动。iOS Simulator编译通过，待随下一次需要用户测试的设备更新发布，不为此重复要求重新连接。

## Mac接通与账号恢复：2026-10-05 23:03 EDT

- Computer History为running，startedAt为2026-10-06T02:55:22Z；本机事件文件02:57:43Z仍有更新，随后实际上下文到达服务。之前stopped是当时的运行状态，不能误写成用户关闭了开关。
- 安装版Mac 0.65.4 (161)原生UI可用；独立Mac配置存到Keychain、启用采集并选择电脑历史目录。服务确认真实mac.activity与mac.history，后者应用/窗口/URL字段可读。
- 通过系统目录选择器以用户主目录覆盖常用学习/开发/文档位置；真实files.activity为available、metadataOnly，覆盖partial-budget。不能以有文件记录推断整棵目录已经扫完。
- Mac日历、提醒事项、device.status亦到达。独立mac.browser当前为permission-or-browser-unavailable；已有电脑历史URL线索不等于该AppleScript通道权限已通过。
- minute_29854260与minute_29854261分别于03:00:08Z、03:01:28Z被正式回调接收。Dot处理仍以它自己的processed_at为准，本会话不代ack。
- Cloudflare已登录既有账号，Sotto/Scritto服务可见；独立时钟已固定该账号、dry-run通过。CLI OAuth等待用户确认新权限，尚未上传Worker或启用Cron。

23:04 EDT用户完成部署授权，whoami核验账号与最少所需OAuth scopes。Worker发布版本17cbba14-f8cc-4a0b-a227-050541ec6ebe为100%；两个secrets经stdin提交，Cloudflare界面显示一分钟Cron、公开URL关闭。当前等待scheduled日志，配置成功不替代运行证据。

Mac第一批minute_29854260于03:01:40.972Z由Dot处理（约94秒）；minute_29854262、63、64之后均出现实际处理回执。无需本会话代ack或重复发送消息去打断Dot。

## 独立分钟Cron验收：2026-10-05 23:12 EDT

Mac采集先通过原生UI关闭，然后仅ingest一条明确synthetic的bridge.probe sequence 3；不手动flush、不代ack。Cloudflare三次scheduledTime为03:10:29Z、03:11:29Z、03:12:29Z，间隔60秒、outcome=ok、无exceptions。首轮batchCreated=true、delivered=1；后两轮无变化，batchCreated=false、delivered=0。

服务确认minute_29854270创建03:10:31.432Z、回调接收03:10:35.370Z、Dot处理03:12:03.903Z，约92秒。首次新Cron配置传播约6分钟；独立转发不依赖Mac上传循环已实测。Mac采集于23:12 EDT恢复开启；03:13:07Z以后新的历史、活动、文件元数据、日历/提醒和设备状态到达服务，恢复后的回执已通过。没有为纯云端配置重复发TestFlight。


## 162 当前验收：2026-10-12

- [x] 双端 TestFlight：VALID、IN_BETA_TESTING，中文测试说明读回核对。完整证据见 state-bridge-release-162.md。
- [x] 云端版本 8 MCP 返回 availability / freshness / coverage / warnings；最新 Mac 七来源有真实上传。
- [x] EventDecisionPolicy / ForwardAllToDots 核心测试；无变化不新建批次；延后判断不丢游标，不阻止旧批次重试。
- [ ] Mac 安装 162 后，正常关闭窗口/普通退出保留菜单栏/真正退出，分别核对采集状态；登录启动选择开启后核对重登。
- [ ] Mac 断网、睡眠唤醒后，队列补传保留发生时间，无重复事件；新观察恢复且最新状态没有倒退。
- [ ] iPhone 安装 162 后，分别核对健康部分失败和正常成功；锁屏/唤醒/重启后记录各来源实际延迟。
- [ ] Edge 中 Dots 普通询问实际调用工具，分别解释旧数据、未上传和读取失败；此处不能用回调收到或 Codex 代读充当验收。
- [ ] Dots 对真实事件处理，并核对 created_at、received_at、processed_at 三个时间；当前数分钟延迟需继续诊断。

此前“Mac 未接通 / Cloudflare 未部署”段落是历史时点记录，不能作为当前状态。162 的真实设备效果尚未核验，保留待测。
