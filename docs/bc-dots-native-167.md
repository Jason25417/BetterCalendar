# BC × Dots：对话确认与指定设备执行（167 增量）

2026-10-13。完整目标仍在推进；本批不含 Aqara 修复、自动强提醒、应用屏蔽或通用多端写入平台。日记的读取与编辑范围已单独问 Jason；计时沿用已有统一 session/revision 入口，真实双端时延继续核验。

Jason已拍板：每次具体改动在Dots对话里点确认，不再另开BC逐次批准。本机设置只需主动启用精确能力，29天有界授权；事项与闹钟独立。原生系统闹钟授权仍只能由用户主动取得。模型写“用户同意”、provenance=user、userConfirmed=true都不能替代按钮凭据。本批后端、原生队列和UI已实现，Dots已实际读取新能力工具；卡片与真实执行仍未验证，不能称完整闭环已验收。

## 用户可见的路径

设置→原生操作→Dots对话操作：本机可分别启用事项池与单次闹钟。Dots读取可用设备/事项版本，提出具体改动并显示确认卡片；你点确认后排给指定设备。原生App约20秒检查队列；iPhone后台可能挂起，尚无后台及时送达保证，打开BC会继续检查。服务接受、等设备、执行中、设备报告完成、失败、未知分开；设备保存不证明另一端已显示或人看到/听到。

事项create(todo)、update标题/备注/状态、delete(todo)、restore；长期事项仍只先放下不删。闹钟schedule/cancel沿用166的AlarmKit协议。计时、事项完成互不代替。照片和日记目前不由此权限开放。

## 独立授权与执行

- MCP `read_native_capabilities` / `submit_native_command` / `read_native_command_status`。`approve_native_command`仅app可见；权限真正依靠账户身份、widget-only随机凭据和固定请求哈希，隐藏工具本身不是授权措施。
- 凭据只返回在工具`_meta`，不进模型正文、研究调用参数或原文导出。确认卡片显示服务保存的完整具体改动，使用textContent，正文不能执行HTML。不支持按钮的客户端保持未确认；不降级为模型批准。
- 本机精确能力/授权版本/期限、服务端用户确认、固定目标设备/请求哈希全部核验后才写入。权限撤回在本机先禁用；云端失败也不会恢复旧权限。服务端每次claim检查当前授权及设备撤销状态。
- 同一commandId不可改payload或执行设备。执行尝试先持久化，同attemptId可重试；接手过但丢失本地日志时禁止新attempt/盲重放。不设租约过期后自动换设备。
- 整页先校验原文与哈希，再逐个执行；分页带固定through。处理回执与research_log原子保存；失败不报告完成。效果已保存但回复丢失用原身份回传；原生166意图日志可用于核对未决写入。可能已发生的效果报unknown，不能冒充失败后随意重复执行。

## 记录、停止与回滚

现有私有StateBridge增加必要操作队列native_grants/native_requests，不复制资料到新服务、不增加事项真相数据库。完整请求及结果供既有本地Recorder按nativeCommandIds下载；执行成功/失败记录也有直接原文定位。批准秘密和设备凭据排除。

原生`DotStateBridge/native-remote-v1.json`保存完整请求、接收/更新时间、同attemptId、尝试次数、授权版本、实际claim、结果和失败记录；原子写，新目录700/文件600，iPhone首次解锁后保护。格式1，上限1000请求/10000失败/16MiB，满或损坏停止新执行并保留原件，无自动删除。现有研究档案配置（365天、2GiB及导出）继续；该原生档案目前需本地文件方式查看/导出，独立容量/保留设置UI仍待增量。

停止：在本机点“撤回全部对话操作”；只撤销新执行，不声称撤销已发生的改动或取消既有闹钟。已排闹钟单独取消；事项可恢复。离线撤权本机立即生效，服务端状态待联网核对。模型或你没反馈均不算认可。

回滚：保留SwiftData、native-actions、native-remote和研究档案，先核对/取消不再需要的系统闹钟。可停止新权限并回退App；云端新增表为增量，不破坏既有设备读取/计时。服务可部署旧版但不删新增表；旧版不会执行此队列。优先前向修复。

## 检查与剩余

已验证：SQLite/MCP组件45/45；Recorder12/12；Mac全量294/294后，新增的离线撤权/效果保存但日志失败恢复与其余7项共9/9通过；iOS Simulator编译成功；TS与服务构建通过。测试均隔离fixture，不创建真实用户事项/闹钟，不伪造反馈。

已验证新增：刷新既有插件后，Dots实际调用read_native_capabilities一次；返回readAt05:14:02.866Z、devices[]。本地研究行17821/17822对应真实开始/返回；页面报告的完整payload规范化哈希与服务记录一致。设备尚无新操作授权记录，不等于设备离线。

未验证：Dots客户端实际卡片显示/按钮回调、167设备安装与主动权限启用、一次用户真正需要的事项/闹钟请求、真实响铃/取消/双端同步时延。真实操作样本不能由假任务代替。

待开发：日记独立MCP读取/写入授权及远程接入；本地协议/实现和9项隔离验证已随后补齐（未包含在167已上传包，见bc-journal-increment.md）。不开放删除。原生日志容量/保留配置和便捷导出；有界自动强提醒继续独立shadow；完整事项字段、全来源、旧史迁移不扩成本批平台。

产品哲学：无持续写日志义务；建议不变成义务；原文/事实不被推断覆盖；操作都可检查且权限可撤回；删除可恢复、长期区不删；开发期失败可见。没有静默修改既有约定。

发布证据将在部署与Apple处理核验后追加，上传开始不算TestFlight可用。

发布核验：7fe98a8已push；服务v21已部署，source067198c0fda279cd587d75bf3729ef63b0f1d4dd，部署appgdep_6acdbacdf2f881919a64e7cbb404d660为succeeded。0.65.10/167双端上传后ASC均VALID、IN_BETA_TESTING、中文说明读回一致，见[evidence/testflight-167.json](evidence/testflight-167.json)。设备安装与真实操作未验。

线上只读证据：正式MCP读到新instructions；已认证Mac native/grant/read返回revision0、capabilities[]，没有开启权限或操作真任务。平台设备凭据读MCP metadata返回401，而native设备API正常，不能把两种身份混作权限失败。Edge Dots01:05 EDT新工具未发现；开发设置刷新后01:14 EDT实际read_native_capabilities调用1次成功，callId research_d3cdd924-7bba-42e7-80e9-65096d7ac3b5，完整返回devices[]的哈希与本地研究记录独立核对一致。研究LaunchAgent25433实查running，保留原档案与游标，已加载新增native原文定位逻辑。[线上检查证据](evidence/native-readiness-167.json)。
