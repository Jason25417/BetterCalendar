# 179现场准备与许可失效提示

2026-10-17 UTC，Jason确认更新、开启两端后，正式MCP已观察到iPhone与Mac均为0.65.22/179、审批通知enabled/authorized。此处不代表用户已看到通知或操作已执行。当前仍为运行中约20秒轮询；没有注册APNs token或启用远程推送。

## 本轮实际证据

- 02:03:11Z只读服务policy revision2，notificationMode=all_reviewers。Mac reviewer绑定grant1；iPhone reviewer仍绑定grant7，而手机有效操作grant已为8。旧reviewer不再有效是既定授权隔离，不能静默重新绑定。
- 02:06:31Z两端各自完整todo读取（complete=true、hasMore=false）中，唯一C5472AF0-89C2-466E-9704-7E260A984C1D均为“BC 联调测试｜通知审批178”、revision35175a9f779a93196b11b8ebff50718221181b8a985ccca625fead50feaafe90，备注及active状态相同。手机观察02:03:40Z，Mac02:06:18Z。证明这一个样本已收敛，不解释此前延迟原因或保证以后同步时限。
- 02:26:27Z用户打开手机后的新目录观察02:26:14Z、接收02:26:26.252Z，同记录/版本仍匹配。只读call research_0c9bb192-f2d9-48e1-8cb6-050e6dd3f61e；grant复查call research_2caef4ac-7e3f-4672-a4aa-5d440ea21b2d。
- 已通过既有Edge扩展向Dots传达一次测试改名：目标iPhone，仅title改为“BC 联调测试｜双端通知179”；手机审批自己的请求，Mac作为有效reviewer接收同一通知。这不能证明手机跨端reviewer已有效。所有具体决定仍由Jason本人完成，不开始计时/响铃。
- 初次因手机快照过期未提交。随后开发指示错误地要求请求内confirmationChannel；Dots如实指出工具无此字段，未发送。已核代码：它是服务整体配置，已明确纠正为现有默认双入口，同一请求可在系统通知批准。没有为绕过宿主而新增参数、改全局配置或创建额外请求。

## 本批代码（准备0.65.23/180，部署与上架状态另记）

- read_native_capabilities新增只读approvalRouting：服务policy版本、通知模式、各设备configured/enabled及受控原因。明确diagnostic_only_rechecked_for_each_request，不代替每次授权核验；不返回密钥、令牌或原文。
- BC内对“本机此前开启，但服务当前未确认有效许可”显示重新确认说明；不自动恢复、不修改权限。自己的请求仍可审批。
- Mac实际只读检查发现原生permitsCrossReview比较Date精确相等：本地grant期限2026-11-11T13:50:21.645133Z，服务同期限经ISO格式传输为.645Z，导致有效许可被拒。Mac可见错误为“本机尚未允许跨设备核对，或审核权限已变更”。已用合成微秒期限测试先复现失败，再改为比较双方的精确ISO毫秒传输值；不是引入时间容差，不接受相差1毫秒的另一期限，仍检查本地持久grant版本、同步标记、当前期限和非空能力。
- 回归核验读取不会更新policy、不会创建路由或命令；grant变化后仍403；原生刷新只显示失效，不自动配置或批准。

## 本地验证

- 服务171/171，0失败/跳过，含8项未接运行时的APNs离线测试；此数字不是推送已接通。新增routing测试在此总数中。
- TypeScript检查及生产build通过。日志/private/tmp/bc-review-status-service-tests.log、-ts.log、-build.log。
- macOS NativeApprovalInboxTests机器摘要32/32，0失败/跳过；xcresult /tmp/bc-loop-dd/Logs/Test/Test-BetterCalendar-2026.10.16_22-27-33--0400.xcresult。包括许可失效提示与不自动恢复。
- 精度回归先红：NativeRemoteExecutionTests新增用例在原代码失败，日志/private/tmp/bc-review-expiry-red.log。修复后审批/执行两suite机器摘要66/66、0失败/跳过，xcresult /tmp/bc-loop-dd/Logs/Test/Test-BetterCalendar-2026.10.16_22-31-18--0400.xcresult；通用iOS device无签名编译exit0。日志保留Xcode现有CoreSimulator版本不兼容与编译诊断，不宣称模拟器可用。
- iPhone新提示真机显示、此次真实通知双端显示/按钮、首决定/设备应用/异端清除仍待验收。Mac聊天2px未修。没有用合成测试替代这些验收。

## 此次真实测试终态：cancelled，没有执行

唯一新请求869e6ee2-90e9-49b6-81c2-a08de612b179，acceptedAt02:28:51.871Z、expiresAt次日02:28:51.693Z，hash f32f5b5313d77ef8a18510ee302ce32185df2c3deacf3a471686747444061380，phone grant8；原revision不变。02:28:58.521Z冻结phone+Mac二设备；phone02:29:02.015Z回报system_submitted（10.144秒），Mac因上述本机核验失败未claim/submit。不是双端通知通过，也不证明手机实际看见。

02:30:18.987Z日志229616收到host_response（action字段，无confirm，userGesture/cause均unknown）；02:30:19.427Z日志229620原子变为cancelled，source=chat_confirmation、resolution=host_cancel。未过期，approvedAt/attemptId/result均空；不是已知本人主动取消。该时段开发向Dots发过“保留原请求等待修复”消息，与回调时间邻近，只是可能解释，缺宿主因果证据，不能确定新消息触发取消。研究日志229036→229666已完整分页；截图/回调字段类型、原hash可定位，不读取宿主私有文件。

此请求保留终态，禁止复活/重放。修复版可安装后才另行安排一个新的具体测试步骤，仍由本人确认；不要让用户继续点此旧卡。不能把系统提交说成用户看到，Mac聊天2px及宿主取消原因仍未修。

## 服务43实际发布与停止/回滚

服务43已于02:34:14Z在原私有Site成功部署，has_mcp=true；source a4c8a48195cdb030494bbe3915f922d3f81237ea，deployment appgdep_6ad2de9caebc8191b31d7e4164ac4065。发布包只从canonical复制5个审批诊断源文件，没有带入离线APNs模块、改表、扩权限或换受众。独立checkout routing19项、TypeScript和生产构建已过。

02:34:33Z正式read_native_capabilities已读到新approvalRouting：all_reviewers、policyRevision2，Mac enabled/active，iPhone configured但disabled/grant_changed_requires_explicit_reconfirmation；call research_dc3d2a55-7ad2-435b-baf3-cfecb4dba03b。只读诊断上线已验证，不等于原生180已安装或通知闭环已通过。

停止本轮测试只停止新提案，不自动改通知设置、撤权限或处理其他真实待办。旧869e请求已取消，无需再次取消。用户可自行关闭本机审批通知；不替用户开关。服务43可回到兼容的42以撤回诊断字段，保留既有路由/投递表和原业务状态；不能为回滚清表。180回到179会重新出现本次跨端精度缺陷，只宜作为已知限制下的回退，不宣称修复仍在。APNs仍未启用；物理验收前不更改原SPEC真实测试复选框。

## 2026-10-17 交接补记

180 双端 xcodebuild 均报告 Upload succeeded（macOS 22:35:58、iOS 22:38:19 EDT），状态文件 stage=uploaded-both；ASC 处理状态与中文测试说明尚未核验。同日起主线转为 SPEC §19（多端审批改走 CloudKit、智能体改用 Claude Code），StateBridge/Dots 线冻结，本文件保留为档案。
