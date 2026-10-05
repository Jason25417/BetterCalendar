# 独立云端分钟时钟

此Worker每分钟调用私有状态服务flush，只做事件转发/过期判断，不调用模型、不采集设备数据、没有公开控制接口。用于Mac睡眠时仍发送服务已经收到的手机变化。

**状态：代码已准备，尚未部署。** 2026-10-05核验已有Wrangler未登录Cloudflare；Sites没有已验证的Cron绑定，不能把普通MCP工具或云任务定时器假装成运行中的一分钟调度器。

启用前：正常连接Cloudflare账户，登记独立clock设备（不可采集个人来源），将STATE_BRIDGE_PLATFORM_TOKEN与STATE_BRIDGE_DEVICE_TOKEN作为Worker secrets提交。凭据通过stdin，不能写wrangler.jsonc、shell参数、Git或日志。再部署此目录，核验Cron实际触发和私有接收回执。当前Mac在线每分钟flush照常可用。

任务计时由服务器时间戳持久化，时钟未运行不影响用户已明确开始/暂停的计时结果；它影响的是自动变化推送时效。
