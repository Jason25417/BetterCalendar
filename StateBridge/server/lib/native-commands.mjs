import { BridgeError, canonical, sha, iso } from './bridge.mjs';
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
export function createNativeCommands(db,time,executeTask){
 const q=(sql,...a)=>db.prepare(sql).bind(...a),one=(sql,...a)=>q(sql,...a).first();
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
 async function submit(v,owner,{formOrigin=null}={}){
  if(formOrigin!==null&&!['submit_native_command','task_command'].includes(formOrigin))throw new BridgeError('未知确认通道');
  if(!text(owner,200))throw new BridgeError('需要账户身份',401);
  // Retry still retrieves historical outcomes after expiry; never re-executes.
  const existing=await one('SELECT * FROM native_requests WHERE command_id=?',v.commandId);
  if(existing){if(existing.owner_id!==owner)throw new BridgeError('请求不存在',404);if(existing.request_hash!==await sha(canonical(v)))throw new BridgeError('同一commandId不可改变请求或设备',409);}
  else{
   const {body,permission}=validate(v),g=await grant(v.deviceId,permission);
   // Require canonical timestamps so retry hashing and the displayed payload match.
   if(canonical(body)!==canonical(v))throw new BridgeError('请使用标准UTC毫秒时间戳');
   await q(`INSERT OR IGNORE INTO native_requests(command_id,device_id,owner_id,request_hash,body,permission,grant_revision,state,accepted_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,v.commandId,v.deviceId,owner,await sha(canonical(body)),canonical(body),permission,g.revision,permission==='journal.read'?'queued':'awaiting_confirmation',time(),body.expiresAt).run();
  }
  const r=await row(v.commandId,owner);if(r.request_hash!==await sha(canonical(v)))throw new BridgeError('同一commandId不可改变请求',409);
  const value=await view(r);let approval=null;
  if(value.state==='awaiting_confirmation'){
   // Opaque MRTR state is a high-entropy nonce, not client-controlled serialized
   // authorization. Its complete value (including originating tool) is hashed
   // in the existing durable request row, which binds owner/body/expiry/grant.
   const token=(formOrigin?`bc-form-v1:${formOrigin}:`:'')+crypto.randomUUID()+crypto.randomUUID();
   const result=await q("UPDATE native_requests SET approval_hash=? WHERE command_id=? AND state='awaiting_confirmation' AND request_hash=?",await sha(token),r.command_id,r.request_hash).run();
   if(changed(result))approval={token,commandId:r.command_id,requestHash:r.request_hash};
  }
  return {value,approval};
 }
 async function approve(v,owner){
  keys(v,['commandId','requestHash','token']);const r=await row(v.commandId,owner);
  if(!text(v.token,200)||await sha(v.token)!==r.approval_hash||v.requestHash!==r.request_hash)throw new BridgeError('必须通过具体改动的确认按钮授权',403);
  if(r.state!=='awaiting_confirmation')return view(r);
  await grant(r.device_id,r.permission,r.grant_revision);if(r.expires_at<=time())throw new BridgeError('确认已过期，请重新提出请求',409);
  await q("UPDATE native_requests SET state='queued',approved_at=? WHERE command_id=? AND state='awaiting_confirmation' AND approval_hash=? AND expires_at>? AND EXISTS(SELECT 1 FROM native_grants WHERE device_id=? AND revision=? AND expires_at>? AND EXISTS(SELECT 1 FROM devices WHERE id=native_grants.device_id AND revoked_at IS NULL))",time(),r.command_id,r.approval_hash,time(),r.device_id,r.grant_revision,time()).run();
  const value=await view(await row(r.command_id,owner));if(value.state!=='queued')throw new BridgeError('授权状态已改变，未交给设备执行',409);return value;
 }
 async function status(v,owner){keys(v,['commandId']);return view(await row(v.commandId,owner));}
 async function respondForm({request,originTool,requestState,response},owner){
  if(!['submit_native_command','task_command'].includes(originTool)||!text(requestState,200)||!requestState.startsWith(`bc-form-v1:${originTool}:`))throw new BridgeError('原生表单确认身份无效',403);
  const r=await row(request.commandId,owner),requestHash=await sha(canonical(request));
  if(r.request_hash!==requestHash||await sha(requestState)!==r.approval_hash)throw new BridgeError('确认原文、设备或凭据已改变',403);
  keys(response,['action','content']);
  if(!['accept','decline','cancel'].includes(response.action))throw new BridgeError('原生确认结果无效');
  if(response.action==='accept'){
   keys(response.content,['confirm']);if(typeof response.content.confirm!=='boolean')throw new BridgeError('原生确认需要本人明确选择');
   if(response.content.confirm===true){
    if(['cancelled','declined'].includes(r.state))throw new BridgeError('本请求已取消或拒绝，不会重新确认或执行',409);
    return approve({commandId:r.command_id,requestHash,token:requestState},owner);
   }
  }else if(response.content!==undefined)throw new BridgeError('取消确认不能混入确认内容');
  // Persist the user's terminal choice. Retain the nonce hash to recognize a
  // lost-response retry, but never renew a closed request or undo an execution.
  const state=response.action==='decline'?'declined':'cancelled';
  if(r.state===state)return view(r);
  if(r.state!=='awaiting_confirmation')throw new BridgeError('本请求已确认或关闭，不能把后来的取消当作撤销执行',409);
  await q("UPDATE native_requests SET state=? WHERE command_id=? AND state='awaiting_confirmation' AND approval_hash=?",state,r.command_id,r.approval_hash).run();
  const fresh=await row(r.command_id,owner);
  if(fresh.state!==state)throw new BridgeError('确认状态已改变，请核对原请求结果',409);
  return view(fresh);
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
  return {readAt:time(),devices:rows.map(r=>({deviceId:r.device_id,label:r.label,revision:r.revision,capabilities:JSON.parse(r.body).capabilities,expiresAt:r.expires_at,confirmation:'chat_button',availability:'execution_requires_device_online_not_heartbeat_proof'}))};
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
 return {capabilities,setGrant,readGrant,submit,approve,status,respondForm,pending,claim,receipt,readJournal,executeTimer};
}
