# 个人状态接入验收（160 / Mac 161）

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

iOS后台不是分钟级定时器。当前没有已验证的独立云端一分钟调度器，分钟flush依在线Mac循环/手机事件；所有设备都离线时不保证主动唤醒，读状态时按expiresAt即时标记stale。旧BetterCalendar数据库模型未改变，无新CloudKit schema部署。

## 真机与诊断回执：2026-10-05 22:44 EDT

iPhone真实来源到达，两个分钟批次均经签名回调接收并由Dot确认处理：第一批约89秒，第二批约161秒。设备→服务→Dot已实测，不能承诺模型每批一分钟内处理完。记录中未保存个人观察内容。Mac/独立云端定时器仍待验收。

Computer Use浏览器操作可用；Computer History工具state=stopped，最新事件文件最后修改为本日11:40 EDT。观察规则默认observe且无例外。运行停止不能证明用户未打开开关；Codex自身设置UI受Computer Use保护，不能自行点开检查。安装版BetterCalendar的原生应用访问当前超时，不再按此前错误结果笼统要求全局授权。

Cloudflare网页显示原先Apple账号的已保存登录profile，但当前为登录页；Wrangler未认证。现有账号可继续使用，账号存在与本机登录是不同状态，未实际部署clock。

发现health.status初次失败后未在成功查询时恢复；源码增加queries-completed回执，仍不把空样本视为授权或无活动。iOS Simulator编译通过，待随下一次需要用户测试的设备更新发布，不为此重复要求重新连接。
