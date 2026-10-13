# iPhone 逐 App 时长：可行性，未新增权限

核验日期：2026-10-13。当前BC仅有Family Controls屏蔽能力；ScreenTimeBlocker不读取、不上传使用时长。ios.app尚无自然观察记录，不能把已获屏蔽权限当作数据访问授权，也不把设备内报告当作已导出。

Apple新API确实提供另一条受支持路径：AuthorizationStatus.approvedWithDataAccess与DeviceActivityData.activityData(filteredBy:using:)自iOS/iPadOS26.4可用，可以取得并导出非匿名的活动数据。正式Xcode27 SDK已实读到对应availability和接口；本次状态心跳报告iPhone为27.2，版本门槛满足，但不是运行成功证明。

条件分别是：

- 新的com.apple.developer.family-controls.app-and-website-usage entitlement与匹配的Apple签名配置；当前BC没有该项。
- 本人明确的数据访问授权；不能把普通approved、代理报告或Mac完全访问当approvedWithDataAccess。同一设备同时只有一个App能持有此授权，新App获准可能使原App授权回到notDetermined。
- 正式用户安装限设备位于EU且Apple Account地区为EU。当前设备/账号地区未核验，不能保证TestFlight分发可用。Apple明确允许使用其提供的provisioning profile在所有地区开发和测试；这需要单独核验匹配配置与本机授权，不能用普通TestFlight成功代替。

结论：为Jason自用准备独立开发签名测试有官方支持依据，尚未接通；不能以“所有地区开发测试可用”推成非EU正式/TestFlight使用可用。当前版本不增加entitlement、不更换配置、不请求此授权，已有屏蔽规则不动。若后续获准实施，还需兼容新的授权状态，避免旧isAuthorized只接受approved而错误解除既有屏蔽。

需要Jason决定的具体增量仅是：是否批准增加这项数据访问能力，并在iPhone亲自同意；同意后先核验development profile和授权，再做只读样本，不扩大成应用屏蔽权限。无需为了本轮修复重新申请已有健康/计时/事项权限。

未启用前的可用范围仍是用户自行配置的快捷指令打开/关闭App事件或本人提供的屏幕使用时间截图：前者覆盖有限，缺事件不代表没使用；后者可做当天粗略回顾，不能证明每段时间的具体行为。不把这两条路径当作全量逐App自动同步。

官方资料：[授权状态与地区/开发限制](https://developer.apple.com/documentation/familycontrols/authorizationstatus/approvedwithdataaccess)、[直接活动数据接口](https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/activitydata(filteredby:using:))、[新增entitlement与本人授权](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls.app-and-website-usage)。网页Markdown与本地SDK相互核验，未来政策或SDK变化需重新检查。
