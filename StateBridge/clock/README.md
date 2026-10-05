# 独立云端分钟时钟

此Worker每分钟调用私有状态服务flush，只做事件转发/过期判断，不调用模型、不采集设备数据、没有公开控制接口。用于Mac睡眠时仍发送服务已经收到的手机变化。

**状态：代码已准备，尚未部署。** 2026-10-05 18:00 UTC核验Wrangler仍未登录Cloudflare。Jason确认复用Sotto/Scritto既有账号；两个项目配置中的Worker分别为sotto-cloud与scritto-cloud，没有绑定可直接使用的本机账号凭据。Sites没有已验证的Cron绑定，不能把普通MCP工具或云任务定时器假装成运行中的一分钟调度器。

启用前：正常连接Cloudflare账户，登记独立clock设备（不可采集个人来源），将STATE_BRIDGE_PLATFORM_TOKEN与STATE_BRIDGE_DEVICE_TOKEN作为Worker secrets提交。凭据通过stdin，不能写wrangler.jsonc、shell参数、Git或日志。再部署此目录，核验Cron实际触发和私有接收回执。当前Mac在线每分钟flush照常可用。

任务计时由服务器时间戳持久化，时钟未运行不影响用户已明确开始/暂停的计时结果；它影响的是自动变化推送时效。

## 2026-10-05 当前准备情况

独立clock已在私有接收端登记，scope仅bridge.clock，不允许采集个人来源。连接配置留在本机 `~/Library/Application Support/BetterCalendarStateBridge/cloud-clock.json`（目录0700、文件0600，未入Git）；接下来用stdin提交为Worker secrets。文件存在不表示Cloudflare部署成功，Cron仍待账号登录与部署后回执。部署对象为新Worker jason-personal-state-clock，保留既有Sotto/Scritto服务。

用户目前仅有手机，Mac应用访问、Computer History和Cloudflare登录待回到电脑处理。iPhone配置已由私有网页登记；服务18:00 UTC仍未收到该机真实观察。把配置粘到iPhone App设置、保存并启用采集，才开始请求OS权限与发送状态。不得把登记成功等同于已采集健康、位置或家居数据。
