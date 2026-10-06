# 独立云端分钟时钟

此Worker每分钟调用私有状态服务flush，只做事件转发/过期判断，不调用模型、不采集设备数据、没有公开控制接口。用于Mac睡眠时仍发送服务已经收到的手机变化。

**状态：独立Worker已部署，真实分钟Cron与Dot处理全链路通过。** 2026-10-05 23:04 EDT在既有Sotto/Scritto账号完成Wrangler授权、空Cron初始部署、经stdin提交两个secrets、最后部署每分钟Cron。当前100%版本为 `17cbba14-f8cc-4a0b-a227-050541ec6ebe`；Cloudflare页面确认Triggers 1、Cron每分钟、No URLs enabled，secret list只核验名称，不读密钥。既有两个服务未作修改。

启用前：正常连接Cloudflare账户，登记独立clock设备（不可采集个人来源），将STATE_BRIDGE_PLATFORM_TOKEN与STATE_BRIDGE_DEVICE_TOKEN作为Worker secrets提交。凭据通过stdin，不能写wrangler.jsonc、shell参数、Git或日志。再部署此目录，核验Cron实际触发和私有接收回执。当前Mac在线每分钟flush照常可用。

任务计时由服务器时间戳持久化，时钟未运行不影响用户已明确开始/暂停的计时结果；它影响的是自动变化推送时效。

## 2026-10-05 当前准备情况

独立clock已在私有接收端登记，scope仅bridge.clock，不允许采集个人来源。连接配置留在本机 `~/Library/Application Support/BetterCalendarStateBridge/cloud-clock.json`（目录0700、文件0600，未入Git），已经stdin提交为Worker secrets。部署对象为新Worker jason-personal-state-clock，保留既有Sotto/Scritto服务；实际运行验收见下方回执。

iPhone与Mac都已收到真实来源，Computer History正在采集，Mac在线分钟flush已送达正式回调。云端时钟已取得实际scheduled回执，并在Mac采集关闭时独立转发合成信号，随后由Dot确认处理。网页登录、设备登记和dry-run均不替代定时运行验收。

部署时先上传crons为空的临时配置，再经stdin提交两个Worker secrets，最后发布每分钟Cron配置。记录deployment/version及scheduled日志，只保留分钟和传输计数。首次Cron配置传播[可能需要最多15分钟](https://developers.cloudflare.com/workers/configuration/cron-triggers/)，不能把部署成功立即当作定时触发已验证。

## 2026-10-05 23:12 EDT 独立运行回执

- Mac采集于23:05 EDT前关闭；23:05:08 EDT仅向ingest写入明确标记synthetic的bridge.probe sequence 3，没有手动flush，也没有伪造手机活动。
- provider scheduledTime依次为03:10:29Z、03:11:29Z、03:12:29Z，实际间隔60秒，三次outcome=ok、exceptions为空。首次配置约6分钟后生效。
- 首轮日志minute=29854270、batchCreated=true、delivered=1、activeSubscriptions=1；后两轮batchCreated=false、delivered=0，无变化不生成批次。
- minute_29854270于03:10:31.432Z创建、03:10:35.370Z回调收到、03:12:03.903Z由Dot实际处理（创建到处理约92秒）。本会话未代ack。
- Mac采集已于23:12 EDT恢复开启；云端时钟不能替代设备采集，也不保证模型分析在一分钟内完成。Wrangler本机登录凭据及设备连接文件权限均为0600，不进入Git/记忆。
