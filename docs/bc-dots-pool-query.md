# 长期事项目录：原生读取与查询接口

2026-10-12。这是整体事项与操作MCP的查询批次；编辑、日程修改及统一旧历史尚未完成。App代码尚未发布，不能据此说Dots已经读到了真实原生目录。

## 谁负责记录

现有LongTask/LongTaskCheckpoint仍由设备SwiftData保存、CloudKit同步。云端只保存设备发布的目录副本，不创建另一份可独立编辑的事项列表，不迁移或改写旧记录。

保留长期区、待办/愿望区、active/done/shelved、回收站以及全部阶段。原有标题、说明、期限、节奏、总量、单元、族、来源日、时间戳和删除元数据保留；不把机会或邀请自动变成义务。日期为Unix毫秒数，保留浮点精度。

每条记录附基于完整内容的revision；阶段或第三方直接修改内容时，即使父事项modifiedAt没有变化，内容版本仍改变。未知分区原字符串保留，读取失败、未保存改动和同UUID重复身份均可见报错，不发布一个假装完整的删减目录。

## 设备到云端

AppContainer注入StateBridgePoolReading；采集周期读取已保存的原库，包含已完成和已放下，不能只读当前UI缓存。测试宿主不安装真实读取器或执行远端副作用。

完整目录编码后按30KiB字节分片（base64传输），最后一条bc.pool清单引用全部分片事件及SHA-256。分片和清单在同一次本地持久化中进入队列；排队失败不推进缓存。重启或重试保留事件身份、序号和发生时间。相同内容重新成功读取时只发布新时间的清单，不重复复制内容；换设备不能复用另一设备分片。

bc.pool.chunk是记录传输片段，不是当前活动；状态摘要包含dataRole=record-fragment且usableForCurrentState=false。bc.pool清单3分钟过期，不能把旧副本当新读取；完整原始观察沿既有长期历史保留。目录超过8MiB会明确失败，原库保留，不悄悄截断。

新增pool/upload与pool/read使用既有交互设备的user.context权限；计时接口也使用此权限。时钟/探针设备不能使用它，普通ingest来源范围没有扩大。私有Site边界保持owner-only。设备登记另要求已登录账户，服务/时钟凭据不能借登记新设备扩大范围；既有设备凭据和连接器授权未改。

## 查询

MCP新增read_pool_records，可按deviceId、zone、status和includeTrash筛选，默认隐藏回收站。返回来源设备、观察/接收时间、时效、内容hash、complete和完整字段。

默认读取最后一份设备目录；保留其他设备目录摘要，若不同则报告deviceViewsDiffer。差异可能是CloudKit延迟，不自动合并、覆盖或裁决。所有原始目录仍可按既有观察历史查询。

每页1至100项，响应按约160KiB分组；遇到单条超预算记录仍完整返回一条并显式byteBudgetExceeded，不丢弃其余项。hasMore时用同一筛选及nextCursor继续；游标固定不可变清单，途中设备更新不会混入下一页。时间仍以固定快照为准。未知格式、损坏、缺分片、错设备、重复身份或数量不符都拒绝假装成功，原始数据保留。

没有原生上传时为not_received/complete=false，不是空目录。真实成功读取的空目录为available/complete=true。设备读取失败为error；工具不能因此说用户没有事项。

Dots说明已补目录来源、分页、版本与状态解释。当前仅查询；没有新增编辑或完成命令。后续写入需内容版本检查、稳定命令ID、原生实际保存回执，以及断网/冲突核验。

## 本轮证据

- macOS应用测试278/278，零跳过/失败：/tmp/bc-pool-tests-verified.xcresult。
- iOS编译通过：/tmp/bc-pool-ios-final.log。
- SQLite26/26、TypeScript和生产构建通过。覆盖115条跨更新分页、原始未来字段、不同设备差异、完整UTF-8长说明、分片缺失/损坏、重复身份、未知版本、授权边界与空/未接入区别。
- 原生验证覆盖四种列表状态、回收站、阶段内容修改、未保存/身份冲突、旧队列兼容、重启防重和切换设备。
- 云端私有v14先上线查询，v15补原生读取入口和传输角色；v16收紧新设备登记，最终源码SHA02e338912df4ed3120309a5970f0163ba54a07e3。
- v16版本appgprj_6ac3bb816d3c8191949bac68d45a62bc~appgver_1d61128fe1088191aebbe7b5fadf1fc5；部署appgdep_6acd1c7aaf488191a19ba202fcb93eef，succeeded/has_mcp=true。地址https://jason-state-bridge.jason25417.chatgpt.site，原私有受众保留。
- 17:39:23 UTC用既有Mac设备凭据实调pool/read成功，返回not_received、complete=false，符合未发布原生读取器的现状。没有上传虚构任务或私人测试副本。17:38 Mac正常心跳仍current，既有采集未被新路由阻断。
- 17:45:33 UTC v16实调：未登录账户时设备登记HTTP401；既有Mac设备pool/read仍成功、not_received/complete=false。没有提供有效登记内容或创建测试设备。
- 当前对话工具目录尚未发现read_pool_records；服务凭据访问MCP端点得到401，不能冒充账户身份绕过。原生设备读取与OAuth MCP调用分开核验；新工具发现、Dots实际调用和真实设备目录上传尚未验收。

本批没有新增SwiftData模型字段或D1表。App更新仍与前批回收站一起等待CloudKit实际字段diff和Production核验，不绕过前置发版。整体goal保持active，P1事项操作和P2历史整体未完成。
