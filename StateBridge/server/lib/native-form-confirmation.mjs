import {BridgeError} from './bridge.mjs';
import {clientConfirmationCapabilities} from './mcp-client-capabilities.mjs';
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export function supportsNativeForm(params) {
 const caps=clientConfirmationCapabilities(params);
 return caps.protocolVersion==='2026-07-28'&&['declared_explicit','declared_implicit'].includes(caps.form);
}
export function nativeFormResponse(params) {
 if(!supportsNativeForm(params))throw new BridgeError('当前宿主没有声明原生表单确认能力',403);
 if(!object(params.inputResponses)||Object.keys(params.inputResponses).length!==1||!object(params.inputResponses.bc_native_confirmation)||typeof params.requestState!=='string')throw new BridgeError('原生表单确认响应不完整');
 return params.inputResponses.bc_native_confirmation;
}
export function nativeFormResult(value,approval) {
 if(!approval||value.state!=='awaiting_confirmation')return null;
 const request=value.request;
 // The complete immutable parameters are shown, including past effective time,
 // target device, revisions and destructive effect. Text is never HTML.
 const kinds={item:'事项',timer:'计时',journal:'日记',alarm:'单次闹钟'};
 const actions={create:'新增',update:'修改',delete:'移入回收站',restore:'恢复',start:'开始',pause:'暂停',resume:'继续',finish:'结束',schedule:'设置',cancel:'取消'};
 const labels={title:'标题',note:'备注',body:'正文',mood:'心情',tags:'标签',status:'状态'};
 const states={active:'进行中',done:'已完成',shelved:'先放下'};
 const edits=Object.entries(request.patch??{}).map(([key,text])=>`${labels[key]??key}：${key==='status'?(states[text]??text):Array.isArray(text)?text.join('、'):text===null?'清空':text}`);
 const details=[request.title?`标题：${request.title}`:null,...edits,request.recordId?`对应记录：${request.recordId}`:null,request.sessionId?`对应计时：${request.sessionId}`:null,request.alarmId?`对应闹钟：${request.alarmId}`:null,request.expectedRevision!==undefined?`核对的原版本：${request.expectedRevision}`:null,request.relatedRecordId?`关联事项：${request.relatedRecordId}`:null,request.effectiveAt?`补记起点（UTC）：${request.effectiveAt}`:request.kind==='timer'?`生效时间：本人确认时，按 BC 服务时间计时`:null,request.fireAt?`响铃时间（UTC）：${request.fireAt}`:null,request.entryDate?`日记日期（UTC）：${request.entryDate}`:null].filter(Boolean);
 const message=`请本人确认：${actions[request.action]??request.action}${kinds[request.kind]??request.kind}。\n${details.join('\n')}\n指定设备：${value.deviceId}\n你的原请求：${request.userRequest}\n有效期限（UTC）：${value.expiresAt}\n取消或不勾选都不会执行；服务接受后仍需核对设备回执。\n请求编号：${value.commandId}`;
 return {resultType:'input_required',inputRequests:{bc_native_confirmation:{method:'elicitation/create',params:{mode:'form',message,requestedSchema:{type:'object',properties:{confirm:{type:'boolean',title:'我确认执行上面的具体改动',default:false}},required:['confirm']}}}},requestState:approval.token};
}
