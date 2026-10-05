# 0.65.3 (160) 个人状态接入验收

2026-10-05。此表区分代码验证与真实使用，不把编译或上传当作采集成功。

## 已验证

- [x] 私有服务正式部署成功，保留owner-private访问。
- [x] 合成观察正式上传被接受，分钟批次生成；此时activeSubscriptions=0，不是Dot处理回执。
- [x] SQLite核心测试4/4：重复/乱序、计时重试/暂停、过期恢复、签名回调重试、纠正保留历史。
- [x] TypeScript检查和Worker构建。
- [x] Mac项目238项单测通过；测试宿主不读Keychain/不启动采集器/不上传。
- [x] iOS Simulator build成功。

## 真实设备与Dot

- [ ] 同一账户连接「个人状态接入」，Dot调用read_instructions/read_connection_status成功。
- [ ] Dot订阅state.minute_changed；挑战验证成功，refreshBefore续约正常。
- [ ] Mac/iPhone分别从私有网页复制配置，保存到Keychain，接受系统权限。
- [ ] mac.activity真实观察到达；切App/进入idle的发生时间和收到时间能对齐。
- [ ] 每个有变化的分钟收到批次；同一批次重试不重复记账；Dot完成处理后出现acknowledge_batch。
- [ ] iPhone睡眠/步数/锻炼读取结果；拒绝读取或缺少样本时显示未知而非没有活动。
- [ ] 后台位置与HealthKit实测更新延迟、电量、锁屏、重启、离线补传。
- [ ] Home传感器分区实测：桌/床位置变动确认映射，离线/无中枢不伪装实时。
- [ ] 每台iPhone快捷指令App/Focus个人自动化实际触发。
- [ ] 对Dot说开始→暂停→继续→结束：工具保存成功后确认，暂停不累计，两端不重复计时。
- [ ] 告诉Dot纠正某推断后，当前解释更新，原观察仍保留。
- [ ] 用户问接下来做什么时，Dot读取最新状态、日程约束与候选，给当前可执行动作。

## 必须保留的限制

iOS后台不是分钟级定时器。当前没有已验证的独立云端一分钟调度器，分钟flush依在线Mac循环/手机事件；所有设备都离线时不保证主动唤醒，读状态时按expiresAt即时标记stale。旧BetterCalendar数据库模型未改变，无新CloudKit schema部署。
