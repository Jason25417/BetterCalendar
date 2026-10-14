import {BridgeError} from './bridge.mjs';
import {clientConfirmationCapabilities} from './mcp-client-capabilities.mjs';
import {canonical,sha} from './bridge.mjs';
import {confirmationPresentation} from './confirmation-presentation.mjs';
import {formResponseShape,normalizeFormResponse} from './native-form-response.mjs';
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export function supportsNativeForm(params) {
 const caps=clientConfirmationCapabilities(params);
 return caps.protocolVersion==='2026-07-28'&&['declared_explicit','declared_implicit'].includes(caps.form);
}
export function nativeFormResponse(params) {
 if(!supportsNativeForm(params))throw new BridgeError('当前宿主没有声明原生表单确认能力',403);
 if(!object(params.inputResponses)||Object.keys(params.inputResponses).length!==1||!object(params.inputResponses.bc_native_confirmation)||typeof params.requestState!=='string'){
  const error=new BridgeError('原生表单确认响应不完整');error.confirmationStage='response.container';throw error;
 }
 return params.inputResponses.bc_native_confirmation;
}
export function nativeFormInputShape(params){
 const responses=params.inputResponses;
 return {requestStateType:typeof params.requestState,inputResponsesType:responses===null?'null':Array.isArray(responses)?'array':typeof responses,
  responseNames:object(responses)?Object.keys(responses).slice(0,24).map(k=>/^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$/.test(k)?k:'[nonstandard-name]'):[],
  missingFields:[...(typeof params.requestState!=='string'?['requestState']:[]),...(!object(responses)||!Object.hasOwn(responses,'bc_native_confirmation')?['bc_native_confirmation']:[])]};
}
export function nativeFormParameters(value,display=null,{preview=false,variant='boolean'}={}) {
 const request=value.request;
 // Operation values are complete plain text. Technical identities/revisions
 // remain bound in the original request and audit rather than in the checkbox.
 const kinds={item:'事项',timer:'计时',journal:'日记',alarm:'单次闹钟'};
 const actions={create:'新增',update:'修改',delete:'移入回收站',restore:'恢复',start:'开始',pause:'暂停',resume:'继续',finish:'结束',schedule:'设置',cancel:'取消'};
 const labels={title:'标题',note:'备注',body:'正文',mood:'心情',tags:'标签',status:'状态'};
 const states={active:'进行中',done:'已完成',shelved:'先放下'};
 const format=(key,text)=>key==='status'?(states[text]??text):Array.isArray(text)?text.join('、'):text===null?'清空':text===''?'（空白）':text===undefined?'（未读取，不能当作空白）':String(text);
 const edits=Object.entries(request.patch??{}).map(([key,text])=>`${labels[key]??key}：${display?.before?format(key,display.before[key])+' → ':''}${format(key,text)}`);
 const title=display?.recordTitle??request.title??(request.kind==='item'&&request.action==='create'?request.patch?.title:null);
 const details=[title?`事项：${title}`:null,`设备：${display?.deviceLabel??value.deviceId}`,...edits,
  request.sessionId?`计时会话：${request.sessionId}`:null,request.alarmId?`闹钟：${request.alarmId}`:null,
  request.effectiveAt?`补记起点（UTC）：${request.effectiveAt}`:request.kind==='timer'?`生效时间：本人确认时，按 BC 服务时间计时`:null,
  request.fireAt?`响铃时间（UTC）：${request.fireAt}`:null,request.entryDate?`日记日期（UTC）：${request.entryDate}`:null,
  display?.source?.freshness==='stale'?`修改前来自旧快照：${display.source.observedAt}；设备仍会核对原版本`:null,
  preview?'仅测试显示；原请求仍是 '+value.state+'，确认、取消均不执行任何操作':`确认期限（UTC）：${value.expiresAt}`].filter(Boolean);
 // The host owns the form's layout. Keep its heading short and put the complete
 // immutable operation in the standard field description, not a long heading.
 // No truncation of changed values, HTML or automatic default approval.
 const message=`${preview?'只读显示测试':'请本人确认'}：${actions[request.action]??request.action}${kinds[request.kind]??request.kind}。`;
 // UUIDs, full revisions and agent-reported userRequest remain in the original
 // immutable request/audit. The human field shows the operation, not a raw dump.
 const description=details.join('\n')+'\n关闭或不勾选都不会执行；服务接受不等于设备已应用。';
 const properties={confirm:{type:'boolean',title:preview?'确认显示测试（不会执行）':'确认执行',description,default:false}};
 if(preview&&variant==='choice')properties.confirm={type:'string',title:'显示测试选择（不会执行）',description,enum:['不执行','确认显示测试'],default:'不执行'};
 if(preview&&variant==='review')return {mode:'form',message,requestedSchema:{type:'object',properties:{review:{type:'string',title:'改动摘要（仅显示测试）',default:description,maxLength:20000},confirm:{...properties.confirm,description:'这次只检查显示和响应格式，不执行原操作。'}},required:['review','confirm']}};
 return {mode:'form',message,requestedSchema:{type:'object',properties,required:['confirm']}};
}
export function nativeFormResult(value,approval,display=null) {
 if(!approval||value.state!=='awaiting_confirmation')return null;
 return {resultType:'input_required',inputRequests:{bc_native_confirmation:{method:'elicitation/create',params:nativeFormParameters(value,display)}},requestState:approval.token};
}

// This separate read-only tool never calls submit/respondForm/approve/claim.
// Even an accept response cannot reopen or execute the referenced command.
export async function previewNativeForm(core,commandId,owner,params,variant='boolean') {
 if(!['boolean','choice','review'].includes(variant))throw new BridgeError('未知只读表单对照');
 const value=await core.nativeCommands.status({commandId},owner);
 if(!supportsNativeForm(params))throw new BridgeError('此宿主未声明表单能力；显示测试未发布，不会执行操作',403);
 if(params.inputResponses!==undefined||params.requestState!==undefined){
  const raw=nativeFormResponse(params);
  if(!params.requestState.startsWith(`bc-preview-v1:${commandId}:`))throw new BridgeError('只读显示测试续传无效');
  await core.research.append('native_confirmation_preview_response',null,{commandId,state:value.state,variant,responseShape:formResponseShape(raw),operationEffect:'read_only'},owner);
  const response=normalizeFormResponse(raw,variant);
  return {value:{preview:true,operationEffect:'read_only',originalCommandId:commandId,originalState:value.state,hostResponse:response.action,executed:false,interpretation:'只读显示测试已返回；没有确认、重建或执行原请求。宿主响应不证明真人看见或点击。'},inputRequired:null};
 }
 const display=await confirmationPresentation(core,value);
 const form=nativeFormParameters(value,display,{preview:true,variant});
 await core.research.append('native_confirmation_preview_prepared',null,{commandId,requestHash:value.requestHash,expectedRevision:value.request.expectedRevision??null,state:value.state,presentationVersion:2,presentationHash:await sha(canonical(form)),beforeSource:display.source,operationEffect:'read_only',hostDisplayed:'unknown'},owner);
 return {value:null,inputRequired:{resultType:'input_required',inputRequests:{bc_native_confirmation:{method:'elicitation/create',params:form}},requestState:`bc-preview-v1:${commandId}:${crypto.randomUUID()}`}};
}

// Internal validation, not an extra external tool call or proof that the host
// displayed a card. Audit persistence failures prevent returning input_required.
export async function finalizeNativeForm(core,value,approval,owner,originTool) {
 if(!approval)return {value,approval:null,inputRequired:null};
 let candidate=null;
 const fresh=await core.research.invoke('mcp/confirmation_finalize',{commandId:value.commandId,requestHash:value.requestHash,grantRevision:value.grantRevision},owner,async()=>{
  const checked=await core.nativeCommands.confirmationSnapshot(approval,owner);
  const display=checked.state==='awaiting_confirmation'?await confirmationPresentation(core,checked):null;
  candidate=nativeFormResult(checked,approval,display);
  if(candidate){
   const params=candidate.inputRequests.bc_native_confirmation.params;
   await core.research.append('native_confirmation_prepared',null,{originTool,commandId:checked.commandId,deviceId:checked.deviceId,requestHash:checked.requestHash,grantRevision:checked.grantRevision,expectedRevision:checked.request.expectedRevision??null,sessionId:checked.request.sessionId??null,expiresAt:checked.expiresAt,state:checked.state,presentationVersion:2,presentationHash:await sha(canonical(params)),beforeSource:display?.source??null,messageCharacters:params.message.length,descriptionCharacters:params.requestedSchema.properties.confirm.description.length,hostDisplayed:'unknown',cancelCause:'unknown'},owner);
  }
  // Recording can take time; never emit the earlier snapshot after expiry,
  // revocation, closure, or another attempt's challenge rotation during it.
  const latest=await core.nativeCommands.confirmationSnapshot(approval,owner);
  if(latest.state!=='awaiting_confirmation'){
   candidate=null;
   await core.research.append('native_confirmation_suppressed',null,{commandId:latest.commandId,requestHash:latest.requestHash,grantRevision:latest.grantRevision,state:latest.state,hostDisplayed:'unknown'},owner);
  }
  return latest;
 });
 return {value:fresh,approval:candidate?approval:null,inputRequired:candidate};
}
