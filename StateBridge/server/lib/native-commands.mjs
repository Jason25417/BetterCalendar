import { BridgeError, canonical, sha, iso } from './bridge.mjs';
import {normalizeFormResponse} from './native-form-response.mjs';
import {createApprovalRouting} from './approval-routing.mjs';
// MCP advertises the same identity contract that the executor validates.
export const nativeUUIDSchema=Object.freeze({type:'string',format:'uuid',pattern:'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'});
const nativeUUIDPattern=new RegExp(nativeUUIDSchema.pattern);
const uuid=v=>typeof v==='string'&&nativeUUIDPattern.test(v);
const permissions=['item.create','item.update','item.delete','item.restore','alarm.schedule','alarm.cancel','journal.read','journal.create','journal.update','timer.start','timer.pause','timer.resume','timer.finish'];
const changed=r=>Number(r?.meta?.changes ?? r?.changes ?? 0);
function keys(v,allowed){if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!allowed.includes(k)||v[k]===undefined))throw new BridgeError('请求包含不支持的字段');}
function text(v,max){return typeof v==='string'&&v.trim().length>0&&v.length<=max;}
// A transport identity is not user intent. Confirmation secrets go only to the
// human widget's _meta, never model text, research logs or command bodies.
export function createNativeCommands(db,time,executeTask,{approvalTTLSeconds=86400,confirmationChannel="chat_form"}={}){
 if(!Number.isSafeInteger(approvalTTLSeconds)||approvalTTLSeconds<300||approvalTTLSeconds>86400)throw new BridgeError("审批默认期限配置必须为300–86400秒",503);
 if(!["native","chat_form"].includes(confirmationChannel))throw new BridgeError("审批渠道配置无效",503);
 const policy=()=>({defaultTTLSeconds:approvalTTLSeconds,maximumTTLSeconds:86400,hostCardLifetime:"unknown_independent_of_service_expiry",defaultConfirmationChannel:confirmationChannel,confirmationChannels:["chat_form","target_device_button"]});
 const resolved=(v,r=null)=>v.expiresAt===undefined?{...v,expiresAt:r?.expires_at??new Date(Date.parse(time())+approvalTTLSeconds*1000).toISOString()}:v;
 const q=(sql,...a)=>db.prepare(sql).bind(...a),one=(sql,...a)=>q(sql,...a).first();
 const routing=createApprovalRouting(db,time,{device,requestView:view,grant:async id=>{
  await device(id);const g=await one('SELECT * FROM native_grants WHERE device_id=?',id);
  if(!g||g.expires_at<=time())throw new BridgeError('跨设备审批需要本机有效授权',403);return g;
 }});
 async function device(id){const d=await one('SELECT * FROM devices WHERE id=?',id);if(!d||d.revoked_at||!JSON.parse(d.scopes).includes('user.context'))throw new BridgeError('指定设备权限已撤回或不存在',403);return d;}
 async function grant(id,permission,revision=null){await device(id);const g=await one('SELECT * FROM native_grants WHERE device_id=?',id);if(!g||g.expires_at<=time()||(revision!==null&&g.revision!==revision)||!JSON.parse(g.body).capabilities.includes(permission))throw new BridgeError('设备操作权限未启用、已到期或已变更',403);return g;}
 async function setGrant(v,d){
  keys(v,['revision','capabilities','expiresAt']);await device(d.id);
  if(!Number.isSafeInteger(v.revision)||v.revision<1||!Array.isArray(v.capabilities)||v.capabilities.some(p=>!permissions.includes(p))||new Set(v.capabilities).size!==v.capabilities.length)throw new BridgeError('操作授权范围或版本无效');
  const expiresAt=iso(v.expiresAt),at=time();if(expiresAt<=at||Date.parse(expiresAt)-Date.parse(at)>30*86400000)throw new BridgeError('授权期限必须在30天内');
  const body=canonical({capabilities:[...v.capabilities].sort(),confirmation:'chat_button'}),prior=await one('SELECT * FROM native_grants WHERE device_id=?',d.id);
  if(prior&&prior.revision===v.revision){if(prior.body!==body||prior.expires_at!==expiresAt)throw new BridgeError('授权版本不可复用于其他范围',409);return {revision:prior.revision,expiresAt:prior.expires_at};}
  if(v.revision!==(prior?.revision??0)+1)throw new BridgeError('授权版本冲突，请重新读取',409);
  const result=await q(`INSERT INTO native_grants(device_id,revision,body,updated_at,expires_at) VALUES(?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET revision=excluded.revision,body=excluded.body,updated_at=excluded.updated_at,expires_at=excluded.expires_at WHERE native_grants.revision=excluded.revision-1`,d.id,v.revision,body,at,expiresAt).run();
  if(!changed(result))throw new BridgeError('授权版本冲突',409);
  return {revision:v.revision,expiresAt};
 }
 async function readGrant(d){await device(d.id);const g=await one('SELECT * FROM native_grants WHERE device_id=?',d.id);return {deviceId:d.id,revision:g?.revision??0,capabilities:g?JSON.parse(g.body).capabilities:[],expiresAt:g?.expires_at??null,confirmation:'chat_button'};}
 function validate(v){
  keys(v,['version','commandId','deviceId','kind','action','recordId','expectedRevision','patch','fireAt','title','alarmId','occurredAt','expiresAt','userRequest','entryDate','query','sessionId','relatedRecordId','effectiveAt']);
  if(v.version!==1)throw new BridgeError('version必须为1');
  if(!uuid(v.commandId))throw new BridgeError('commandId必须是UUID，不能使用任务名或日期拼接；尚未接收此请求。仅此格式拒绝可更正编号，已接收请求必须沿用原commandId');
  if(!text(v.deviceId,80))throw new BridgeError('deviceId需要指定设备身份（最多80字符）');
  if(!text(v.userRequest,2000))throw new BridgeError('userRequest需要用户请求原文（最多2000字符；原文仅代理报告，不能替代本人确认）');
  const at=time(),occurredAt=iso(v.occurredAt),expiresAt=iso(v.expiresAt);
  if(Date.parse(occurredAt)>Date.parse(at)+120000||expiresAt<=at||Date.parse(expiresAt)-Date.parse(at)>86400000)throw new BridgeError('请求时间无效或已过期');
  let permission;
  if(v.kind!=='timer'&&['sessionId','relatedRecordId','effectiveAt'].some(k=>v[k]!==undefined))throw new BridgeError('非计时请求不能混入计时字段');
  if(v.kind==='timer'){
   if(!['start','pause','resume','finish'].includes(v.action)||['recordId','patch','fireAt','alarmId','entryDate','query'].some(k=>v[k]!==undefined))throw new BridgeError('计时请求无效');
   if(v.action==='start'){if(!text(v.title,300)||v.sessionId!==undefined||v.expectedRevision!==undefined||v.relatedRecordId!==undefined&&!text(v.relatedRecordId,150))throw new BridgeError('开始计时需要标题，不能混入旧会话或版本');}
   else if(!text(v.sessionId,80)||!Number.isSafeInteger(v.expectedRevision)||v.expectedRevision<1||v.title!==undefined||v.relatedRecordId!==undefined)throw new BridgeError('计时操作需要原会话与整数版本');
   if(v.effectiveAt!==undefined&&(iso(v.effectiveAt)!==v.effectiveAt||v.effectiveAt>at))throw new BridgeError('明确补记的计时时刻需要标准UTC毫秒时间，不能在未来');
   permission=`timer.${v.action}`;
  }else if(v.kind==='item'){
   if(!['create','update','delete','restore'].includes(v.action)||!uuid(v.recordId))throw new BridgeError('事项操作或身份无效');
   if(v.action==='create'&&v.expectedRevision!=null||v.action!=='create'&&!text(v.expectedRevision,150))throw new BridgeError('事项操作需要正确的原始版本');
   const patch=v.patch??{};keys(patch,['title','note','status']);
   if(patch.title!==undefined&&!text(patch.title,500)||patch.note!==undefined&&(typeof patch.note!=='string'||patch.note.length>16000)||patch.status!==undefined&&!['active','done','shelved'].includes(patch.status))throw new BridgeError('事项字段无效');
   if(v.action==='create'&&!patch.title||['delete','restore'].includes(v.action)&&Object.keys(patch).length)throw new BridgeError('创建需要标题，删除/恢复不可混入改动');
   if(['fireAt','title','alarmId','entryDate','query'].some(k=>v[k]!==undefined))throw new BridgeError('事项请求混入闹钟字段');
   permission=`item.${v.action}`;
  }else if(v.kind==='alarm'){
   if(!['schedule','cancel'].includes(v.action)||['recordId','expectedRevision','patch','entryDate','query'].some(k=>v[k]!==undefined))throw new BridgeError('闹钟请求无效');
   if(v.action==='schedule'){if(!text(v.title,150)||v.alarmId!==undefined||iso(v.fireAt)<=at)throw new BridgeError('闹钟需要未来时间和标题');}
   else if(!uuid(v.alarmId)||v.fireAt!==undefined||v.title!==undefined)throw new BridgeError('取消闹钟需要原闹钟身份');
   permission=`alarm.${v.action}`;
  }else if(v.kind==='journal'){
   if(!['read','create','update'].includes(v.action)||['fireAt','title','alarmId'].some(k=>v[k]!==undefined))throw new BridgeError('日记操作无效');
   if(v.action==='read'){
    if(['recordId','expectedRevision','patch','entryDate'].some(k=>v[k]!==undefined))throw new BridgeError('日记读取不能混入写入字段');
    journalQuery(v.query??{});
   }else{
    if(!uuid(v.recordId)||v.query!==undefined||v.action==='create'&&(v.expectedRevision!=null||v.entryDate===undefined)||v.action==='update'&&(!text(v.expectedRevision,150)||v.entryDate!==undefined))throw new BridgeError('日记需要创建日期或原始版本');
    if(v.entryDate!==undefined&&iso(v.entryDate)!==v.entryDate)throw new BridgeError('日记日期需要UTC毫秒时间戳');
    const patch=v.patch??{};keys(patch,['body','mood','tags']);
    if(!Object.keys(patch).length||patch.body!==undefined&&(typeof patch.body!=='string'||new TextEncoder().encode(patch.body).length>16000)||patch.mood!==undefined&&patch.mood!==null&&(typeof patch.mood!=='string'||patch.mood.length>100)||patch.tags!==undefined&&(!Array.isArray(patch.tags)||patch.tags.length>30||patch.tags.some(t=>!text(t,100))))throw new BridgeError('日记文字、心情或标签无效');
   }
   permission=`journal.${v.action}`;
  }else throw new BridgeError('尚不支持此原生操作');
  return {body:{...v,occurredAt,expiresAt,...(v.fireAt?{fireAt:iso(v.fireAt)}:{})},permission};
 }
 async function row(id,owner){const r=await one('SELECT * FROM native_requests WHERE command_id=?',id);if(!r||owner!==undefined&&r.owner_id!==owner)throw new BridgeError('请求不存在',404);return r;}
 async function view(r){
  let state=r.state;
  if(['awaiting_confirmation','queued'].includes(state)){if(r.expires_at<=time())state='expired';else try{await grant(r.device_id,r.permission,r.grant_revision);}catch{state='revoked';}}
  return {version:1,nativeCommandId:r.command_id,commandId:r.command_id,deviceId:r.device_id,requestHash:r.request_hash,request:JSON.parse(r.body),permission:r.permission,grantRevision:r.grant_revision,state,acceptedAt:r.accepted_at,expiresAt:r.expires_at,approvedAt:r.approved_at,attemptId:r.attempt_id,result:r.result?JSON.parse(r.result):null,resultAt:r.result_at,serverAccepted:true,deviceApplication:r.state==='applied'?(r.permission==='journal.read'?'device_reported_read':'device_reported_applied'):r.state==='failed'?'device_reported_failed':'unknown',userSeen:'unknown',operationEffect:r.permission==='journal.read'?'read_only':'mutation',userRequestEvidence:r.permission==='journal.read'?'read_allowed_by_independent_device_grant':'agent_report_confirmation_required'};
 }
 /** @param {any} v @param {string} owner @param {{formOrigin?: 'submit_native_command'|'task_command'|null}} [options] */
 async function submit(v,owner,{formOrigin=null}={}){
  if(formOrigin!==null&&!['submit_native_command','task_command'].includes(formOrigin))throw new BridgeError('未知确认通道');
  if(!text(owner,200))throw new BridgeError('需要账户身份',401);
  // Retry still retrieves historical outcomes after expiry; never re-executes.
  const implicitExpiry=v.expiresAt===undefined;
  const existing=await one('SELECT * FROM native_requests WHERE command_id=?',v.commandId);
  v=resolved(v,existing);
  if(existing){if(existing.owner_id!==owner)throw new BridgeError('请求不存在',404);if(existing.request_hash!==await sha(canonical(v)))throw new BridgeError('同一commandId不可改变请求或设备',409);}
  else{
   const {body,permission}=validate(v),g=await grant(v.deviceId,permission);
   // Require canonical timestamps so retry hashing and the displayed payload match.
   if(canonical(body)!==canonical(v))throw new BridgeError('请使用标准UTC毫秒时间戳');
   await q(`INSERT OR IGNORE INTO native_requests(command_id,device_id,owner_id,request_hash,body,permission,grant_revision,state,accepted_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,v.commandId,v.deviceId,owner,await sha(canonical(body)),canonical(body),permission,g.revision,permission==='journal.read'?'queued':'awaiting_confirmation',time(),body.expiresAt).run();
  }
  const r=await row(v.commandId,owner);
  // Two identical first deliveries may independently generate deadlines before
  // either INSERT is visible. The winning immutable row owns that deadline.
  if(implicitExpiry)v={...v,expiresAt:r.expires_at};
  if(r.request_hash!==await sha(canonical(v)))throw new BridgeError('同一commandId不可改变请求',409);
  let value=await view(r);let approval=null;
  if(value.state==='awaiting_confirmation'&&!r.approval_hash){
   // Opaque MRTR state is a high-entropy nonce, not client-controlled serialized
   // authorization. Its complete value (including originating tool) is hashed
   // in the existing durable request row, which binds owner/body/expiry/grant.
   const token=(formOrigin?`bc-form-v1:${formOrigin}:`:'')+crypto.randomUUID()+crypto.randomUUID();
   const tokenHash=await sha(token),at=time();
   const result=await q("UPDATE native_requests SET approval_hash=? WHERE command_id=? AND state='awaiting_confirmation' AND approval_hash IS NULL AND request_hash=? AND expires_at>? AND EXISTS(SELECT 1 FROM native_grants WHERE device_id=? AND revision=? AND expires_at>? AND EXISTS(SELECT 1 FROM devices WHERE id=native_grants.device_id AND revoked_at IS NULL))",tokenHash,r.command_id,r.request_hash,at,r.device_id,r.grant_revision,at).run();
   const fresh=await row(r.command_id,owner);value=await view(fresh);
   if(changed(result)&&value.state==='awaiting_confirmation'){
    if(fresh.approval_hash!==tokenHash)throw new BridgeError('确认凭据已更新，请核对原请求；不要重复发布确认',409);
    approval={token,commandId:r.command_id,requestHash:r.request_hash};
   }
  }
  return {value,approval};
 }
 function conflict(message,value){const error=new BridgeError(message,409);error.current=value;return error;}
 async function decide(r,decision,actor,resolution="explicit_button",reviewGuard=null){
  const current=await view(r);
  if(decision==='accept'&&r.approved_at)return current;
  const state=decision==='accept'?'queued':decision==='decline'?'declined':'cancelled';
  if(r.state===state&&decision!=='accept')return current;
  if(r.state!=='awaiting_confirmation')throw conflict('本请求已有决定，请核对最新状态',current);
  if(['expired','revoked'].includes(current.state)){
   if(decision!=='accept')return current;
   throw conflict('请求已过期或授权已撤回，不会执行',current);
  }
  await grant(r.device_id,r.permission,r.grant_revision);
  const request=JSON.parse(r.body),at=time();
  if(decision==='accept'&&request.kind==='alarm'&&request.action==='schedule'&&request.fireAt<=at)throw conflict('响铃时间已过，不再批准这条排程',current);
  // Decision and receipt commit together. A failed durable receipt rolls back
  // approval; the first competing decision wins the conditional UPDATE.
  await db.batch([
   q("UPDATE native_requests SET state=?,approved_at=? WHERE command_id=? AND owner_id=? AND request_hash=? AND state='awaiting_confirmation' AND grant_revision=? AND expires_at>? AND EXISTS(SELECT 1 FROM native_grants g JOIN devices d ON d.id=g.device_id WHERE g.device_id=? AND g.revision=? AND g.expires_at>? AND d.revoked_at IS NULL AND EXISTS(SELECT 1 FROM json_each(g.body,'$.capabilities') WHERE value=?))"+(reviewGuard?' AND '+reviewGuard.sql:''),state,decision==='accept'?at:null,r.command_id,r.owner_id,r.request_hash,r.grant_revision,at,r.device_id,r.grant_revision,at,r.permission,...(reviewGuard?.args??[])),
   q("INSERT OR IGNORE INTO research_log(call_id,kind,actor,created_at,body) SELECT ?,?,?,?,? WHERE changes()>0",`native_decision_${r.command_id}`,'native_approval_decision',actor,at,canonical({version:1,commandId:r.command_id,requestHash:r.request_hash,grantRevision:r.grant_revision,decision,state,priorStoredState:r.state,priorEffectiveState:current.state,resolution,producer:'authenticated_transport',producerGesture:'not_observed',cancelCause:'unknown',source:actor.startsWith('device:')?'native_button':'chat_confirmation',userGesture:'transport_report_not_independent_observation'}))
  ]);
  const fresh=await row(r.command_id),value=await view(fresh);
  if(decision!=='accept'&&['expired','revoked'].includes(value.state))return value;
  if(decision==='accept'&&fresh.approved_at||decision!=='accept'&&fresh.state===state)return value;
  throw conflict('审批状态已改变，请核对最新状态',value);
 }
 async function approve(v,owner){
  keys(v,['commandId','requestHash','token']);const r=await row(v.commandId,owner);
  if(!text(v.token,200)||await sha(v.token)!==r.approval_hash||v.requestHash!==r.request_hash)throw new BridgeError('必须通过具体改动的确认按钮授权',403);
  return decide(r,'accept',`owner:${owner}`);
 }
 async function status(v,owner){keys(v,['commandId']);return view(await row(v.commandId,owner));}
 async function confirmationSnapshot(v,owner){
  keys(v,['commandId','requestHash','token']);const r=await row(v.commandId,owner);
  if(r.request_hash!==v.requestHash)throw new BridgeError('确认请求身份已改变',409);
  const value=await view(r);
  if(value.state==='awaiting_confirmation'&&(!text(v.token,200)||await sha(v.token)!==r.approval_hash))throw new BridgeError('确认凭据已更新，请核对原请求；不要重复发布确认',409);
  return value;
 }
 async function confirmationIdentity(request,owner){
  const r=await one('SELECT * FROM native_requests WHERE command_id=? AND owner_id=?',request.commandId,owner);
  return {storedState:r?.state??null,effectiveState:r?(await view(r)).state:null,expiresAt:r?.expires_at??null,approvedAt:r?.approved_at??null,requestHash:r?.request_hash??null,candidateRequestHash:await sha(canonical(resolved(request,r)))};
 }
 async function respondForm({request,originTool,requestState,response},owner){
  if(!['submit_native_command','task_command'].includes(originTool)||!text(requestState,200)||!requestState.startsWith(`bc-form-v1:${originTool}:`))throw Object.assign(new BridgeError('原生表单确认身份无效',403),{confirmationStage:'binding.origin_or_challenge_format'});
  const r=await row(request.commandId,owner),requestHash=await sha(canonical(resolved(request,r)));
  if(r.request_hash!==requestHash)throw Object.assign(new BridgeError('确认原文或设备已改变',403),{confirmationStage:'binding.request_hash'});
  if(await sha(requestState)!==r.approval_hash)throw Object.assign(new BridgeError('确认凭据已改变',403),{confirmationStage:'binding.challenge'});
  response=normalizeFormResponse(response);
  if(response.action==='accept'){
   if(typeof response.content.confirm!=='boolean')throw new BridgeError('原生确认需要本人明确选择');
   if(response.content.confirm===true){
    try{return await approve({commandId:r.command_id,requestHash,token:requestState},owner);}catch(e){e.confirmationStage??='authorization.grant_expiry_or_decision';throw e;}
   }
  }else if(response.content!==undefined)throw new BridgeError('取消确认不能混入确认内容');
  // Host cancellation is not proof of a user gesture and cannot undo another
  // channel's decision. Same decisions are idempotent; opposites return state.
  try{return await decide(r,response.action==='decline'?'decline':'cancel',`owner:${owner}`,response.action==='accept'?'host_accept_unchecked':response.action==='decline'?'host_decline':'host_cancel');}catch(e){e.confirmationStage??='decision.transition';throw e;}
 }
 async function approvalStatus(v,d){
  keys(v,['commandId']);await device(d.id);const r=await row(v.commandId);
  await routing.allowed(r,d);
  return approvalView(r,d);
 }
 async function approvalView(r,d){
  const value=await view(r);
  if(r.device_id!==d.id){
   const g=await one('SELECT * FROM native_grants WHERE device_id=?',d.id);
   const p=await routing.read(d);
   value.reviewContext={reviewerDeviceId:d.id,grantRevision:g.revision,policyRevision:p.revision,expiresAt:g.expires_at,executionDeviceId:r.device_id,authority:'explicit_cross_device_review'};
  }
  return value;
 }
 async function approvalList(v,d){
  keys(v,['after','through','limit','includeShared']);await device(d.id);const limit=v.limit??20;
  if(v.includeShared!==undefined&&typeof v.includeShared!=='boolean')throw new BridgeError('跨设备审批读取选择无效');
  if(!Number.isSafeInteger(limit)||limit<1||limit>20||v.after!==undefined&&typeof v.after!=='string'||v.through!==undefined&&typeof v.through!=='string')throw new BridgeError('审批分页无效');
  const shared=v.includeShared!==false&&await routing.canReview(d.id),filter=shared?'1=1':'device_id=?',args=shared?[]:[d.id];
  // Include retained results so an unselected card on another device can
  // converge too; effective states below still apply expiry/revocation.
  const retained="(state IN ('awaiting_confirmation','queued','dispatching') OR accepted_at>=?)",cutoff=new Date(Date.parse(time())-30*86400000).toISOString();
  const through=v.through??(await one(`SELECT MAX(command_id) upper FROM native_requests WHERE ${filter} AND ${retained}`,...args,cutoff)).upper??'';
  const rows=(await q(`SELECT * FROM native_requests WHERE ${filter} AND ${retained} AND command_id>? AND command_id<=? ORDER BY command_id LIMIT ?`,...args,cutoff,v.after??'',through,limit+1).all()).results;
  const commands=[];for(const r of rows.slice(0,limit))commands.push(await approvalView(r,d));
  return {commands,nextCursor:commands.at(-1)?.commandId??v.after??'',through,hasMore:rows.length>limit,approvalPolicy:policy()};
 }
 async function decideFromDevice(v,d){
  keys(v,['commandId','requestHash','grantRevision','expectedRevision','decision','reviewerGrantRevision','reviewerPolicyRevision']);await device(d.id);const r=await row(v.commandId);
  await routing.allowed(r,d);
  if(v.requestHash!==r.request_hash||v.grantRevision!==r.grant_revision||!['accept','decline'].includes(v.decision))throw new BridgeError('本机审批身份、版本或选择无效',403);
  const request=JSON.parse(r.body);
  if(canonical(v.expectedRevision??null)!==canonical(request.expectedRevision??null))throw new BridgeError('审批所读版本与原请求不一致',409);
  let guardValue=null;
  if(r.device_id!==d.id){
   if(!Number.isSafeInteger(v.reviewerGrantRevision)||!Number.isSafeInteger(v.reviewerPolicyRevision))throw new BridgeError('跨设备审批需要本机审核权限版本',403);
   guardValue=routing.decisionGuard(d.id,v.reviewerGrantRevision,v.reviewerPolicyRevision);
  }else if(v.reviewerGrantRevision!==undefined||v.reviewerPolicyRevision!==undefined)throw new BridgeError('本机请求不能混入其他审核权限',400);
  await decide(r,v.decision,`device:${d.id}`,'explicit_button',guardValue);
  return approvalStatus({commandId:r.command_id},d);
 }
 async function pending(v,d){
  keys(v,['after','through','limit']);await device(d.id);const limit=v.limit??10;
  if(!Number.isSafeInteger(limit)||limit<1||limit>10||v.after!==undefined&&typeof v.after!=='string'||v.through!==undefined&&typeof v.through!=='string')throw new BridgeError('队列分页无效');
  // UUID lexicographic ordering freezes the offered range; new earlier IDs are
  // picked up next poll from the beginning, never acknowledged as a whole batch.
  const through=v.through??(await one("SELECT MAX(command_id) upper FROM native_requests WHERE device_id=? AND state IN ('queued','dispatching')",d.id)).upper??'';
  const rows=(await q("SELECT * FROM native_requests WHERE device_id=? AND command_id>? AND command_id<=? AND state IN ('queued','dispatching') ORDER BY command_id LIMIT ?",d.id,v.after??'',through,limit+1).all()).results;
  const commands=[];for(const r of rows.slice(0,limit))commands.push(await view(r));
  return {commands,nextCursor:commands.at(-1)?.commandId??v.after??'',through,hasMore:rows.length>limit};
 }
 async function claim(v,d){
  keys(v,['commandId','requestHash','attemptId']);await device(d.id);const r=await row(v.commandId);
  if(r.device_id!==d.id||v.requestHash!==r.request_hash||!uuid(v.attemptId))throw new BridgeError('设备、请求或执行身份不匹配',403);
  if(['applied','failed','unknown'].includes(r.state))return view(r);
  await grant(d.id,r.permission,r.grant_revision);if(r.expires_at<=time())throw new BridgeError('请求过期，不再执行',409);
  if(r.state==='dispatching'){if(r.attempt_id!==v.attemptId)throw new BridgeError('已有执行尝试，结果未知，不可换身份重试',409);return view(r);}
  if(r.state!=='queued'||r.permission!=='journal.read'&&!r.approved_at)throw new BridgeError('请求未由用户确认',403);
  await q("UPDATE native_requests SET state='dispatching',attempt_id=?,claimed_at=? WHERE command_id=? AND state='queued' AND expires_at>? AND EXISTS(SELECT 1 FROM native_grants WHERE device_id=? AND revision=? AND expires_at>? AND EXISTS(SELECT 1 FROM devices WHERE id=native_grants.device_id AND revoked_at IS NULL))",v.attemptId,time(),r.command_id,time(),d.id,r.grant_revision,time()).run();
  const fresh=await row(r.command_id);if(fresh.state!=='dispatching'||fresh.attempt_id!==v.attemptId)throw new BridgeError('执行权已改变，请核对原请求',409);return view(fresh);
 }
 async function receipt(v,d){
  keys(v,['commandId','requestHash','attemptId','outcome','receipt']);await device(d.id);const r=await row(v.commandId);
  if(r.device_id!==d.id||r.request_hash!==v.requestHash||r.attempt_id!==v.attemptId||r.permission!=='journal.read'&&!r.approved_at||!['applied','failed','unknown'].includes(v.outcome)||!v.receipt||typeof v.receipt!=='object'||Array.isArray(v.receipt))throw new BridgeError('执行回执身份或结果无效',403);
  if(new TextEncoder().encode(canonical(v.receipt)).length>48000)throw new BridgeError('执行回执过大',413);
  const resultHash=await sha(canonical(v));if(r.result_hash){if(r.result_hash!==resultHash)throw new BridgeError('原回执不可覆盖，纠正需独立记录',409);return view(r);}
  if(r.state!=='dispatching')throw new BridgeError('请求尚未分配给设备',409);
  const at=time();
  await db.batch([
   q("UPDATE native_requests SET state=?,result_hash=?,result=?,result_at=? WHERE command_id=? AND state='dispatching' AND result_hash IS NULL",v.outcome,resultHash,canonical(v.receipt),at,r.command_id),
   q("INSERT OR IGNORE INTO research_log(call_id,kind,actor,created_at,body) SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM native_requests WHERE command_id=? AND result_hash=?)",`native_result_${r.command_id}`,'native_result',`device:${d.id}`,at,canonical({version:1,nativeCommandId:r.command_id,requestHash:r.request_hash,attemptId:v.attemptId,outcome:v.outcome,resultHash}),r.command_id,resultHash)
  ]);
  const fresh=await row(r.command_id);if(fresh.result_hash!==resultHash)throw new BridgeError('执行回执冲突，不能声称完成',409);return view(fresh);
 }
 async function executeTimer(v,d){
  keys(v,['commandId','requestHash','attemptId']);await device(d.id);const r=await row(v.commandId),request=JSON.parse(r.body);
  if(r.device_id!==d.id||r.request_hash!==v.requestHash||r.attempt_id!==v.attemptId||r.state!=='dispatching'||!r.approved_at||request.kind!=='timer')throw new BridgeError('计时必须由已确认请求的指定设备接手',403);
  await grant(d.id,r.permission,r.grant_revision);if(r.expires_at<=time())throw new BridgeError('计时请求过期，不再执行',409);
  const command={commandId:r.command_id,action:request.action,occurredAt:request.effectiveAt??r.approved_at,provenance:'user'};
  if(request.action==='start'){command.title=request.title;if(request.relatedRecordId!==undefined)command.relatedRecordId=request.relatedRecordId;}
  else{command.sessionId=request.sessionId;command.expectedRevision=request.expectedRevision;}
  // The mutation repeats these checks in the same SQLite transaction. A revoke
  // between the awaited reads and the write cannot leave a changed session.
  return executeTask(command,`confirmed-device:${d.id}`,{commandId:r.command_id,requestHash:r.request_hash,attemptId:r.attempt_id,deviceId:d.id,permission:r.permission,grantRevision:r.grant_revision});
 }
 async function capabilities(){
  const rows=(await q('SELECT g.device_id,g.revision,g.body,g.expires_at,d.label FROM native_grants g JOIN devices d ON d.id=g.device_id WHERE d.revoked_at IS NULL AND g.expires_at>? ORDER BY g.device_id',time()).all()).results;
  return {readAt:time(),approvalPolicy:policy(),devices:rows.map(r=>({deviceId:r.device_id,label:r.label,revision:r.revision,capabilities:JSON.parse(r.body).capabilities,expiresAt:r.expires_at,confirmation:'chat_button',availability:'execution_requires_device_online_not_heartbeat_proof'}))};
 }
 function journalQuery(v){
  keys(v,['start','end','text','includeTrash','limit','cursor']);
  if(v.start!==undefined&&iso(v.start)!==v.start||v.end!==undefined&&iso(v.end)!==v.end||v.start!==undefined&&v.end!==undefined&&v.start>=v.end||v.text!==undefined&&(typeof v.text!=='string'||v.text.length>1000)||v.includeTrash!==undefined&&typeof v.includeTrash!=='boolean'||v.limit!==undefined&&(!Number.isSafeInteger(v.limit)||v.limit<1||v.limit>50)||v.cursor!==undefined&&(typeof v.cursor!=='string'||v.cursor.length>2000))throw new BridgeError('日记读取范围或分页无效');
 }
 async function readJournal(v,owner){
  keys(v,['commandId','deviceId','query']);if(!text(owner,200))throw new BridgeError('需要账户身份',401);
  if(!uuid(v.commandId))throw new BridgeError('commandId必须是UUID；读取尚未接收，更正格式后保持同一编号查询结果');
  if(!text(v.deviceId,80))throw new BridgeError('deviceId需要指定设备身份（最多80字符）');journalQuery(v.query??{});
  const previous=await one('SELECT * FROM native_requests WHERE command_id=?',v.commandId);
  if(previous){const r=await row(v.commandId,owner),body=JSON.parse(r.body);if(r.permission!=='journal.read'||r.device_id!==v.deviceId||canonical(body.query)!==canonical(v.query??{}))throw new BridgeError('同一读取身份不可改变范围或设备',409);return view(r);}
  try {
   const submitted=await submit({version:1,commandId:v.commandId,deviceId:v.deviceId,kind:'journal',action:'read',query:v.query??{},occurredAt:time(),expiresAt:new Date(Date.parse(time())+3600000).toISOString(),userRequest:'Read-only journal retrieval; permission is independent native journal.read grant'},owner);
   return submitted.value;
  }catch(error){
   // Concurrent identical reads may each generate internal timestamps before
   // either row is visible. Retrieve the winning immutable request, rather
   // than treating its timestamp as a caller payload change or issuing a new ID.
   if(error instanceof BridgeError&&error.status===409){
    const latest=await one('SELECT * FROM native_requests WHERE command_id=?',v.commandId);
    if(latest){const r=await row(v.commandId,owner),body=JSON.parse(r.body);if(r.permission==='journal.read'&&r.device_id===v.deviceId&&canonical(body.query)===canonical(v.query??{}))return view(r);}
   }
   throw error;
  }
 }
 return {policy,capabilities,setGrant,readGrant,submit,approve,status,confirmationSnapshot,confirmationIdentity,respondForm,approvalList,approvalStatus,decideFromDevice,pending,claim,receipt,readJournal,executeTimer,routing};
}
