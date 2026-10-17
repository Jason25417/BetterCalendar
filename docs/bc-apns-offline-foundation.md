# APNs离线准备：未接通真实推送

本批仅完成provider和持久尝试状态的离线核心，不导入现有Worker入口，不新增路由或数据库表，不注册设备token，不读取实际Apple私钥，不修改权限，不部署，不重发TestFlight。线上仍服务42/App179；开启BC后台推送及token/凭据处理的授权问题仍待本人回答。已有生产entitlement不等于服务已接通。

## 已实现、已隔离验证

- `apns-provider.mjs`默认关闭，且没有默认网络实现；只有显式enabled、注入fetcher与credentials才可尝试发送。测试私钥临时生成，只在测试内存使用。
- 固定BC topic及Apple production/sandbox域名；拒绝重定向、无效token格式、超过4096字节的payload、超过64字节的collapse ID、过期/超过24小时的期限，以及把有alert/sound/badge的内容伪装成background。token按可变长度处理，不假设32bytes。
- 内存ES256 JWT、20分钟内复用；结果不回传私钥、JWT、token、原始响应或错误正文。对400/403/410/429/500/503等已知Apple原因分类；不认识的响应、超时或ID不匹配保持unknown。410失效时间只是后续token版本核验的依据，尚未接入真实token撤回。
- `apns-attempt.mjs`要求外部durable store提供原子claim/finish；commandId、hash、设备、token版本、grant/reviewer版本、expectedRevision和期限在领取前后核对。provider接受后回执保存失败不假称成功；保留reserved，重开store后不盲重发。已明确拒绝与不确定结果分开，不自动重试或本地补响。
- 8项离线测试通过，0失败/跳过。含临时SQLite关闭/重开及重建dispatcher、双实例竞争、持久化失败、撤权、绑定/版本/期限不匹配、生产请求格式和真实可校验的临时ES256签名。**没有实际Worker进程重启、真实Apple请求或设备送达测试。** 结果日志`/private/tmp/bc-apns-offline-tests.log`。

## 下一步仍需要做

1. 本人选择APNs方案后，再接设备token注册/轮换/撤回、本机独立opt-in、provider秘密配置。不得把App Store Connect密钥自动当APNs key，或记录秘密值。
2. 把claim/finish适配到现有per-device通知投递状态，且本地poll与APNs必须竞争同一份预留，不能各建一个可发送队列。当前离线合同不是已上线的D1 outbox。
3. 请求接收后的入队、明确拒绝后的有界调度、截止时间/授权复查和token失效版本竞争。重试保留同APNs ID及原commandId，不凭collapse ID承诺exactly-once。
4. 完整审批payload与原生binding对齐；长内容只打开详情，任何具体同意/拒绝都要重新读取同一服务状态。Apple接受、设备收到、系统可见和用户操作分别记，不把其中之一替代其他。
5. 一端决定后清理其他端通知；后台状态变化只能作为刷新提示，不能保证唤醒或远程即时删除。过时按钮仍须服务端拒绝，不能扩大权限。
6. 在现有生产Worker核验HTTP/2/provider真实路径，之后才验收两端锁屏/后台/退出/断网与重复投递。离线fetch mock不证明HTTP/2可用；不另建未经批准的服务兜底。

## 核实过的依据与边界

- [Apple：Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)：provider用HTTP/2+TLS；APNs属于best effort，可能重排、限流或不送达，expiration也不是严格送达保证。collapse ID用于合并展示，不是BC决定或执行授权。
- [Apple：Establishing a connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns)：生产与开发端点应分开。
- [Cloudflare Fetch文档](https://developers.cloudflare.com/workers/runtime-apis/fetch/)描述Worker请求接口；没有据此认定本地Node/Workerd的普通fetch等于已验证的APNs HTTP/2链路。
- [Cloudflare workerd原始问题4841](https://github.com/cloudflare/workerd/issues/4841)有维护仓库内的用户报告“生产Worker可用、本地macOS失败”。这是未经本项目独立复现的报告，只用于提示需分开验环境，**不作为BC生产可用证据**。

本批不为改善通过率绕开授权，也不把这些离线模块称作已完成后台推送。SPEC F02仍保留整体未完成。
