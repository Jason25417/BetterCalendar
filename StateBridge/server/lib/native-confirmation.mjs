export const nativeConfirmationUri='ui://bc/native-confirmation-v1.html';
// Public receipt contract; human approval credentials remain outside it in _meta.
const textSchema={type:'string'},nullableText={type:['string','null']};
export const nativeCommandOutputSchema={
 type:'object',additionalProperties:false,
 properties:{version:{type:'integer',enum:[1]},nativeCommandId:textSchema,commandId:textSchema,deviceId:textSchema,requestHash:textSchema,
  request:{type:'object',additionalProperties:true},permission:textSchema,grantRevision:{type:'integer',minimum:1},
  state:{type:'string',enum:['awaiting_confirmation','queued','dispatching','applied','failed','unknown','expired','revoked','cancelled','declined']},
  acceptedAt:textSchema,expiresAt:textSchema,approvedAt:nullableText,attemptId:nullableText,result:{type:['object','null'],additionalProperties:true},resultAt:nullableText,
  serverAccepted:{type:'boolean',enum:[true]},deviceApplication:{type:'string',enum:['unknown','device_reported_read','device_reported_applied','device_reported_failed']},
  userSeen:{type:'string',enum:['unknown']},operationEffect:{type:'string',enum:['read_only','mutation']},
  userRequestEvidence:{type:'string',enum:['agent_report_confirmation_required','read_allowed_by_independent_device_grant']},
  approvalUI:{type:'object',properties:{channel:{type:'string',enum:['target_device_button']},deviceLabel:textSchema,title:textSchema,expiresAt:textSchema,instructions:textSchema},required:['channel','deviceLabel','title','expiresAt','instructions'],additionalProperties:false},
  research:{type:'object',properties:{callId:textSchema,responseHash:textSchema,recorded:{type:'boolean'}},required:['callId','responseHash','recorded'],additionalProperties:false}},
 required:['version','nativeCommandId','commandId','deviceId','requestHash','request','permission','grantRevision','state','acceptedAt','expiresAt','approvedAt','attemptId','result','resultAt','serverAccepted','deviceApplication','userSeen','operationEffect','userRequestEvidence','research']
};
// No third-party resources, fetch, localStorage or secrets in model context.
export const nativeConfirmationHtml=String.raw`<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
body{font:15px system-ui;margin:0;padding:16px;color:CanvasText;background:Canvas}h2{font-size:18px;margin:0 0 12px}pre{white-space:pre-wrap;word-break:break-word;font:14px system-ui}button{font:inherit;padding:9px 16px;margin-right:8px;border-radius:8px;border:1px solid #888;cursor:pointer}button:disabled{opacity:.5;cursor:default}#status{line-height:1.6}
</style><h2>确认这次 BC 操作</h2><p id="status" role="status">正在读取具体改动…</p><pre id="details"></pre><button id="approve" disabled>确认并交给这台设备</button><button id="refresh" disabled>查看执行结果</button><script>
const pending=new Map();let serial=0,output=null,approval=null,bridgeReady=false;
const status=document.getElementById('status'),details=document.getElementById('details'),button=document.getElementById('approve'),refresh=document.getElementById('refresh');
const labels={awaiting_confirmation:'等待你确认；尚未执行',queued:'已确认，等待指定设备上线执行',dispatching:'设备已接手；执行结果尚未回传',applied:'设备已报告完成；其他设备同步和你是否看到仍需核对',failed:'设备报告失败，请查看原因',unknown:'结果未知；请核对，勿重新创建同一操作',expired:'请求已过期，未执行',revoked:'权限已撤回或变更，未再执行',cancelled:'确认已关闭；尚未执行。可能是关闭对话框或加载中断，原因未核实；这次请求不会重新执行',declined:'确认已被拒绝；尚未执行，不再弹出这次确认'};
function metadata(m){return m?.approval??m?.mcp_tool_result?._meta?.approval??m?.call_tool_result?._meta?.approval??null;}
function render(value,meta){if(!value?.nativeCommandId)return;output=value;approval=metadata(meta)??approval;
 status.textContent=labels[value.state]??'状态尚未核实';
 const r=value.request;details.textContent=JSON.stringify({指定设备:value.deviceId,操作:r.kind+'.'+r.action,用户请求:r.userRequest,事项身份:r.recordId,原始版本:r.expectedRevision,计时会话:r.sessionId,关联事项:r.relatedRecordId,具体改动:r.patch,日记归属时刻:r.entryDate?new Date(r.entryDate).toLocaleString():undefined,读取范围:r.query,闹钟时间:r.fireAt?new Date(r.fireAt).toLocaleString():undefined,标题:r.title,提醒正文:r.body,普通提醒身份:r.reminderId,提醒声音:r.sound,合成测试:r.experiment,计时生效:r.kind==='timer'?(r.effectiveAt?'明确补记：'+new Date(r.effectiveAt).toLocaleString():'以本次按钮确认的BC服务时刻为准；指定设备上线后执行，版本冲突不覆盖，结束计时不完成事项'):undefined,取消闹钟:r.alarmId,确认期限:new Date(value.expiresAt).toLocaleString(),结果:value.result},null,2);
 button.disabled=!bridgeReady||value.state!=='awaiting_confirmation'||!approval?.token||approval.requestHash!==value.requestHash;refresh.disabled=!bridgeReady;
}
function request(method,params){if(window.openai?.callTool&&method==='tools/call')return window.openai.callTool(params.name,params.arguments);
 return new Promise((resolve,reject)=>{const id=++serial;const timer=setTimeout(()=>{pending.delete(id);reject(Error('响应未收到，请查看原请求结果，勿改commandId重试'));},15000);pending.set(id,{resolve,reject,timer});window.parent.postMessage({jsonrpc:'2.0',id,method,params},'*');});}
window.addEventListener('message',event=>{if(event.source!==window.parent||event.data?.jsonrpc!=='2.0')return;const m=event.data;
 if(pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(m.error.message??'调用失败')):p.resolve(m.result);}
 if(m.method==='ui/notifications/tool-result')render(m.params?.structuredContent,m.params?._meta);
});
function globals(){if(window.openai?.toolOutput){bridgeReady=typeof window.openai.callTool==='function';render(window.openai.toolOutput,window.openai.toolResponseMetadata);}}
window.addEventListener('openai:set_globals',globals);globals();
if(!bridgeReady)request('ui/initialize',{appInfo:{name:'BC confirmation',version:'1.0.0'},appCapabilities:{},protocolVersion:'2026-01-26'}).then(()=>{bridgeReady=true;window.parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized'},'*');if(output)render(output,null);}).catch(()=>{if(!bridgeReady)status.textContent='此对话尚未提供确认按钮能力；操作保持未确认。';});
async function call(name,args){const result=await request('tools/call',{name,arguments:args});if(result?.isError)throw Error(result.content?.[0]?.text??'操作未确认');if(result?.structuredContent)render(result.structuredContent,result._meta);else throw Error('未收到可核验结果，操作状态未知');}
button.onclick=async()=>{button.disabled=true;try{await call('approve_native_command',approval);}catch(e){status.textContent=e.message;refresh.disabled=false;}};
refresh.onclick=async()=>{refresh.disabled=true;try{await call('read_native_command_status',{commandId:output.nativeCommandId});}catch(e){status.textContent=e.message;refresh.disabled=false;}};
</script></html>`;
/** @param {any} value @param {any} [approval] */
export function nativeToolResult(value,approval=null){return{resultType:'complete',content:[{type:'text',text:JSON.stringify(value)}],structuredContent:value,...(approval?{_meta:{approval}}:{}),isError:false};}
