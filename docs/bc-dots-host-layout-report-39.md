# Dots 原生确认表单桌面尺寸问题：最小宿主报告

2026-10-14，服务v39，原生0.65.19/176。**电脑聊天布局仍未修好。** BC内确认与聊天必须同时保留，不能用一个入口通过替代另一个。已向官方Help客服发送下附脱敏报告；当前官方要求登录，尚无人工接单/工单编号/宿主修复回执。没有公开发布私人聊天、设备身份、令牌或HAR。

## 本轮真实证据

Edge/macOS，chatgpt.com/dots/home，viewport1462×804 CSS px、DPR2。新创建的联调测试提案在有效期内pending，DOM里有正文、默认未勾选的确认控件、取消和继续按钮。外行768px；bubble/fieldset/card均2px；内部form0px、720px高；card722px高且overflow:hidden。完整计算样式见[evidence/dots-host-ancestors-39.json](evidence/dots-host-ancestors-39.json)。这与用户报告Mac待确认竖线一致，但不冒充已抓取原生Mac应用的DOM。

本人在Dots15:56 EDT报告手机正常并已确认，随后电脑才显示出已结束卡。独立正式状态读取核验同请求批准19:56:03.191Z、Mac实际SwiftData保存19:56:06.530Z，结果applied/local_store_saved。Dots另报告已读回测试待办标题与备注。最终用户屏幕显示/CloudKit另一端同步仍unknown；Mac聊天pending仍失败。

## 尺寸机制与候选修复（强线索，不是线上已修）

request-card具有container-type:inline-size。CSS标准草案说明inline-size containment在计算固有行内尺寸时不使用子内容；外层bubble则flex:0 1 auto、min-width:0、没有明确preferred width，max-width本身不能提供目标宽度。此组合有形成只剩两条边框的收缩尺寸的强线索。

独立假数据[HTML复现](evidence/dots-host-css-isolated.html)实际在Edge得到同样row768/card2/form0。审批专用bubble给定明确inline-size，并让中间层、card、form铺满后，同样768外行得到card512/form510；窄358外行card285/form283，按钮可换行、未裁剪。记录[计算结果](evidence/dots-host-css-isolated-results.json)与[截图](evidence/dots-host-css-isolated.png)。无网络API、真实确认或业务操作；窄容器不是iPhone真机。

宿主候选补丁应限定elicitation消息，保留普通聊天气泡逻辑。例如：

```css
/* 示意选择器；实际组件源文件、data属性需宿主所有者确定。 */
.elicitation-message .message-bubble-wrap {
  inline-size: min(32rem, calc(100% - 73px));
  min-inline-size: 0;
}
/* 完整中间层须有确定百分比参照，不能仅给最内层width:100%。 */
.elicitation-message .message-content-line,
.elicitation-message .message-content,
.elicitation-message .request-card,
.elicitation-message form { inline-size: 100%; }
.elicitation-message .request-card-footer { flex-wrap: wrap; }
```

宿主还须验证pending首次绘制、取消/完成后的重布局、手机/桌面和放大比例；在请求有效时正文/勾选框/提交即可见。不得默认勾选、自批、取消原请求重建来规避。BC不能通过form JSON修改这些宿主CSS，也未注入生产宿主CSS。

## 需要宿主提供的确切缺失证据

1. 当前Dots原生表单组件及message-bubble的源文件/前端构建号和尺寸计算；审批消息是否错误依赖contained card固有宽度。
2. 待确认与完成状态渲染分支、Portal挂载时序、宽度/ResizeObserver日志；手机决定导致桌面恢复的实际触发。
3. 早先cancelled回调的宿主事件生产者与触发原因；BC知道回调action并不证明用户主动取消。旧缺失字段和旧取消来源仍unknown，不追认本轮证据。
4. 如果有正式服务端布局兼容字段，请给出协议/文档与支持客户端；不能把MCP Apps iframe尺寸API套在原生form。

## 官方文档与公开检索

- [OpenAI Extended forms](https://developers.openai.com/plugins/build/extensions#extended-forms)：requestedSchema/oneOf及MRTR说明；未列原生卡宽高覆盖字段。本轮客户端form=declared_implicit、ui=not_declared，因此未启用未经声明支持的widget替代。
- [CSS containment草案](https://drafts.csswg.org/css-contain-2/#containment-inline-size)：解释固有尺寸机制，不证明宿主具体源文件已修。
- [社区其他空白widget报告](https://community.openai.com/t/chatgpt-android-skips-resources-read-for-mcp-widgets-text-renders-widget-stays-blank/1379702)：是resources/read缺失的MCP Apps案例，与本次正文已在DOM但2px裁剪不同，不能套用结论。
- [Dots权限社区讨论](https://community.openai.com/t/dots-explicit-approval-isn-t-carrying-through-delegated-tasks/1402896)：官方建议持续问题携时间/截图联系Support，不是本次布局修复。
- [官方客服入口](https://help.openai.com/en/articles/6614161-how-can-i-contact-support)：本轮使用客服对话，不使用内容违法举报或文章thumbs-down冒充技术工单。

截至本轮检索未发现与本次2px/pending→completed完全吻合的公开解决方案。未提交未脱敏HAR。以下为实际发入官方客服窗口的文本（身份验证尚未完成）：

我们在联调一个私人 MCP 应用 BetterCalendar，想请你们帮忙排查 Dots 电脑端的原生确认表单布局。请将这份脱敏报告转给负责 Dots / form elicitation 的团队，而不是建议取消确认或改用另一个入口。

2026-10-14 19:52 UTC，在 macOS 的 Edge 打开 chatgpt.com/dots/home，通过 submit_native_command 发出一条真实但独立的测试待办创建提案。标准 form 需要本人勾选 confirm=true 再提交，默认不勾选。请求仍有效时，Mac 上几乎只剩一条竖线，正文和按钮不可见。用户在 iPhone Dots 正常看到了并确认后，Mac 才展开到能看到内容。BC 服务之后核验到同一请求 approved、设备 applied/local_store_saved；这不表示 Mac 布局通过。

只读 DOM 测量（待确认状态，viewport 1462×804，DPR 2）：
- article.message-row：768px 宽；
- .message-bubble-wrap：2px，flex:0 1 auto，min-width:0，max-width:min(88%,100% - 73px)；
- 中间 message-content / message-body / fieldset 同为2px；
- request-card：2px宽、722px高，container-type:inline-size、overflow:hidden、1px border；
- 内部 form：0px宽、720px高。正文、未勾选的确认控件及取消/继续按钮都已入DOM，但被裁剪。

我们另做了完全不联网的最小CSS隔离复现：自动收缩的flex bubble + inline-size containment，稳定得到card=2px/form=0px；给审批专用bubble明确inline-size、让中间层/card填满该宽度后，同样768px外行下card=512px/form=510px。358px可用区域也能正常排版。这里只证明尺寸机制，不声称已修复你们的宿主。

目前最强的假设是：inline-size containment切断内容的固有宽度贡献，而外层bubble依赖内容自动收缩，最终只剩边框。需要宿主确认并修复审批专用外层的宽度约束，以及 pending→completed 的重布局。我们无法访问宿主源码。

已核对官方 Extended forms 文档与 MCP 2026-07-28 form/MRTR；没有找到控制宿主原生确认卡宽高的服务端字段。客户端声明 form=declared_implicit、ui=not_declared，不能把 MCP Apps iframe 的尺寸API当成当前原生form的修复。

请问：是否已有同类已知问题或正式服务端兼容方式？如果需要宿主修复，请提供工单编号并转交前端团队。我们可以继续提供只含假数据的HTML/CSS复现与计算样式；不上传令牌、完整聊天、用户事项或未脱敏HAR。浏览器具体版本、宿主前端构建号及原生Mac客户端DOM尚未采集，不把它们当作已知。
