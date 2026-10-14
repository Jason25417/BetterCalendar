# 确认布局：已定位宿主宽度问题，BC 修复待真实两端验收

本轮只改 StateBridge 的确认呈现与防重复逻辑。原生保持 0.65.17 / 174，不改权限、数据库、事项或计时。产品审查：保留本人具体确认、可恢复与代理不代权；只读显示测试不记真实活动，符合原型边界。开发失败继续可见。服务发布状态以证据 JSON 为准。

## 原始事件与定位

`518db08f-af21-4c4f-99be-56d70d7d73c2` 在 2026-10-14 02:51:19.353Z 接受，03:03:25Z 到期；02:51:20.677Z 准备一次表单，02:51:56.832Z 收到宿主 cancel，02:51:57.297Z 转 cancelled。批准、执行尝试、结果均空。关闭发生于到期前；不能说已过期，也不能说本人主动取消。发布通知同 messageId 重到不证明两张卡。

按本地保存的原请求与当时源码重建实际 form 参数，哈希与 prepared 记录精确匹配：`4d06ea6c…b57356ef442572`，标题 11 字符、boolean description 358 字符。只使用标准 form/boolean，未返回 HTML、高度或空白占位；实际缺少直观事项名和修改前值，仅在代理报告的原话中提及。原 JSON 受控保存在本机 `/private/tmp/bc-confirmation-35-original-form.json`（0600），不含 requestState，不加入 Git。

本轮通过 Edge 扩展直接测量同一已关闭卡片的 DOM。1912×931 CSS viewport，DPR=2；外部 message-row 宽 768px，message-bubble-wrap 和 request-card 宽仅 2px。form 宽0、高847/max-height847；shrink-0 header 内容高5836、宽36；request-card overflow hidden。截图确有巨幅空白，同一 commandId 的 form 计数1。这里是实际计算样式，区别于之前截图像素约337的推测。

这证明宿主存在收缩宽度与裁剪的问题；不能据此还原原始待处理期间的加载事件。网页本次加载有 React #418，但它发生在02:55:53，不能当作02:51取消原因。仍缺待处理时的同一 messageId/commandId 宿主收到、挂载、布局和关闭时间，以及 cancel 生产来源/错误栈；iPhone 原生宿主尺寸也缺。没有接管受限 ChatGPT 应用、修改宿主 CSS 或访问私有会话内部状态。

## BC 实际修改

- 事项修改/删除/恢复的显示从指定设备的完整、固定快照分页取原事项，并与 expectedRevision 对齐；显示名称、设备标签和修改前后。字段未知不当作空白，快照未齐、找不到事项、版本不符、分页无法继续明确报“确认内容加载失败”，不发布不完整改动卡。
- 已改值不截断、仍为纯文本；UUID、完整版本和代理报告的原话保留在原请求/日志，不挤入勾选说明。保留明确期限与旧快照标记；默认不勾选。宿主按钮名称/加载错误提示/容器高度不能由 BC 设定。
- 同一已接收请求只原子生成一次挑战；并发与重启重试返回原状态，不轮换凭据、不再返回 input_required。旧卡凭据仍绑定原 owner/requestHash/device/revision/grant/期限；关闭/过期不重建、不执行。首次响应丢失或审计失败可能留下无法继续确认的待处理请求，保持未知/等待，不以自动重发代替，用户重新明确提出需求才另行处理。
- 原生提案不再同时广告旧 HTML widget 与 native form；既有资源及 widget-only approve 仍保留，禁止模型调用。此为消除双呈现歧义，不能称旧元数据已证实造成空白；旧不支持原生 form 的宿主不再自动得到 widget 展示，不擅自改用其他批准方式。
- `preview_native_confirmation(commandId)` 是独立只读显示测试。原请求即使已关闭也仅作为展示参考；确认/取消/拒绝均不调用批准、队列、设备或计时，不重建原操作，不写活动。标签明确“不会执行”，响应仅证明宿主回传，不冒充人看见/点击；没有新授权。

## 已验证与未验证

103/103 服务隔离测试，0失败/跳过；构建成功。新增覆盖原值读取与分页/版本/缺口、完整长文本、预览三种宿主结果无写入、预览状态不能授权真实操作、并发8份提案只有一张表单、重启/重复请求不轮换。保留过期、撤权、请求/session/revision篡改、审计持久化失败与丢失回执测试。

未验证：修复后的 Mac 原生 Dots 和 iPhone 真机布局、有效期内按钮实际可用、真实本人确认后的设备应用及双端同步。Edge 已关闭旧卡的观察不代替这些验收。

## 最小宿主问题报告

Dots 原生 form 在正常宽聊天内收缩为2px，header shrink-0 使内容高5836px，form max-height847px与外层overflow:hidden裁掉具体改动/控件。BC 已提供完整标准表单，仅准备一次；宿主约37秒后在到期前cancel，原因unknown，未执行。请检查 message-bubble-wrap 的 flex intrinsic width、原生 request-card 的宽度约束及 header/body/footer 的滚动/收缩分工，确保有效期内正文和按钮可见。关联：上述commandId、prepared presentationHash；不要重建原请求。React #418仅是本次重载线索。需补原始待处理时序与 Mac/iPhone 宿主日志，不能凭 closed DOM 宣称根因全部找到。

## 验收、停止与回滚

先只做显示：让 Dots 调用 `preview_native_confirmation`，引用原commandId；两端查看同一只读测试，确认名称、设备、空白→临时备注、勾选和提交/取消是否可见。实际业务操作仍需另一次本人明确需求与本人确认；本轮不安排。

停止：关闭显示测试即可，无操作要撤销。回滚服务源到 v34 对应 `1744d383…` 并重新发布同一 private Site，保留现有请求/回执、不重开原已关闭命令。无需回滚原生174或做数据迁移。本轮是否已发布/真正两端验收见 [证据](evidence/confirmation-layout-35.json)。

规范依据：[MCP form elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation)、[OpenAI 原生表单说明](https://developers.openai.com/plugins/build/extensions)。二者描述内容与协议，不承诺宿主具体宽高。
