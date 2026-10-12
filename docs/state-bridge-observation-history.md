# 来源历史查询（云端版本 9）

2026-10-12。本批只读原始观察，不迁移或覆盖旧 BC 记录，不修改计时、计划或完成状态。云端源 commit 6ce4e946cbde56394125e4069fc7289f0e9feddf 已私有部署成功；没有为纯云端查询重复发 TestFlight。

`read_observation_history` 使用 `sourceKey`（从 read_current_state 获取）、可选带时区 from / before、limit（1–100，默认30）、cursor。按 occurred/observed 时间与 eventId 排序；返回 observedAt 和 receivedAt、完整 observation、hasMore / nextCursor。保留未知 schemaVersion 与扩展字段。历史不是当前状态，也不是确认的任务。

分页保留首批 before 与 asOfReceivedAt，继续时保持查询条件并传 nextCursor。每页按条数和约180KiB预算限制，不截断单条观察；单条外部异常记录超预算时明确失败并保留原文件/记录。晚到数据不会混进当前分页；要复核补传，请从第一页重新读取该时间窗。空结果只表示此查询没有记录。

新增 D1 索引 idx_observations_source_time（source_key,observed_at,id）；只追加 0003 迁移，未改旧迁移，也不改观察内容。原始记录长期保留，30天回收站仍待实现，不由此查询宣称已具备。

12项真实 SQLite 核心测试通过；新增覆盖同时间分页、Unicode ID、未知版本/字段、补传排序、范围/游标校验、响应预算、旧数据库加索引前后逐字一致及查询计划使用索引。TypeScript与服务build通过。生产部署成功；Dots 已报告 14:32:20Z 对 Mac device.status 以 limit=1 调用成功；Codex 随后也通过正式 MCP 调用同一来源窄时间窗成功（只输出数量与时间），工具发现与生产调用均已核验。

Dots诊断：Jason在Edge打开 https://chatgpt.com/dots/home 后，Codex已从消息框发送获准只读诊断；页面显示已读，Dots回复确认只读核查。此前缺失会话ID未送达与本次已送达分别记录，不能据旧ID失败认定不能联系Dots。Dots 诊断确认当前工具可发现且可调用；历史有未发现插件、读取取消/批次不完整两类记录，不能把所有历史问题统一归因于过期。事件回调数秒收到，processed_at 可晚数分钟甚至约38分钟；现有回执不含队列/调度细分，原因未核验。

10:36 EDT：当前完全访问下再次使用 send_message_to_thread，已不报审批策略错误，但仍返回 thread not found；read_thread 返回空历史的占位信息并不证明可发信。已验证的联系入口仍为 Edge dots 首页。Mac 162 已通过原生版本标签核验，重新启动后队列为0、保存时间持续更新；登录启动已开启，普通退出保留菜单栏原本开启。尚未重登/重启验收，退出原因未定；未见当前 BC 崩溃报告。
