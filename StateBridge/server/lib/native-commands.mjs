import { BridgeError, canonical, sha, iso } from './bridge.mjs';
const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
const permissions=['item.create','item.update','item.delete','item.restore','alarm.schedule','alarm.cancel'];
const changed=r=>Number(r?.meta?.changes ?? r?.changes ?? 0);
function keys(v,allowed){if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!allowed.includes(k)))throw new BridgeError('请求包含不支持的字段');}
function text(v,max){return typeof v==='string'&&v.trim().length>0&&v.length<=max;}
// A transport identity is not user intent. Confirmation secrets go only to the
// human widget's _meta, never model text, research logs or command bodies.
export function createNativeCommands(db,time){
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
  keys(v,['version','commandId','deviceId','kind','action','recordId','expectedRevision','patch','fireAt','title','alarmId','occurredAt','expiresAt','userRequest']);
  if(v.version!==1||!uuid(v.commandId)||!text(v.deviceId,80)||!text(v.userRequest,2000))throw new BridgeError('需要固定请求/设备身份和用户请求原文（原文仅代理报告）');
  const at=time(),occurredAt=iso(v.occurredAt),expiresAt=iso(v.expiresAt);
  if(Date.parse(occurredAt)>Date.parse(at)+120000||expiresAt<=at||Date.parse(expiresAt)-Date.parse(at)>86400000)throw new BridgeError('请求时间无效或已过期');
  let permission;
  if(v.kind==='item'){
   if(!['create','update','delete','restore'].includes(v.action)||!uuid(v.recordId))throw new BridgeError('事项操作或身份无效');
   if(v.action==='create'&&v.expectedRevision!=null||v.action!=='create'&&!text(v.expectedRevision,150))throw new BridgeError('事项操作需要正确的原始版本');
   const patch=v.patch??{};keys(patch,['title','note','status']);
   if(patch.title!==undefined&&!text(patch.title,500)||patch.note!==undefined&&(typeof patch.note!=='string'||patch.note.length>16000)||patch.status!==undefined&&!['active','done','shelved'].includes(patch.status))throw new BridgeError('事项字段无效');
   if(v.action==='create'&&!patch.title||['delete','restore'].includes(v.action)&&Object.keys(patch).length)throw new BridgeError('创建需要标题，删除/恢复不可混入改动');
   if(['fireAt','title','alarmId'].some(k=>v[k]!==undefined))throw new BridgeError('事项请求混入闹钟字段');
   permission=`item.${v.action}`;
  }else if(v.kind==='alarm'){
   if(!['schedule','cancel'].includes(v.action)||['recordId','expectedRevision','patch'].some(k=>v[k]!==undefined))throw new BridgeError('闹钟请求无效');
   if(v.action==='schedule'){if(!text(v.title,150)||v.alarmId!==undefined||iso(v.fireAt)<=at)throw new BridgeError('闹钟需要未来时间和标题');}
   else if(!uuid(v.alarmId)||v.fireAt!==undefined||v.title!==undefined)throw new BridgeError('取消闹钟需要原闹钟身份');
   permission=`alarm.${v.action}`;
  }else throw new BridgeError('尚不支持此原生操作');
  return {body:{...v,occurredAt,expiresAt,...(v.fireAt?{fireAt:iso(v.fireAt)}:{})},permission};
 }
 async function row(id,owner){const r=await one('SELECT * FROM native_requests WHERE command_id=?',id);if(!r||owner!==undefined&&r.owner_id!==owner)throw new BridgeError('请求不存在',404);return r;}
 async function view(r){
  let state=r.state;
  if(['awaiting_confirmation','queued'].includes(state)){if(r.expires_at<=time())state='expired';else try{await grant(r.device_id,r.permission,r.grant_revision);}catch{state='revoked';}}
  return {version:1,nativeCommandId:r.command_id,commandId:r.command_id,deviceId:r.device_id,requestHash:r.request_hash,request:JSON.parse(r.body),permission:r.permission,grantRevision:r.grant_revision,state,acceptedAt:r.accepted_at,expiresAt:r.expires_at,approvedAt:r.approved_at,attemptId:r.attempt_id,result:r.result?JSON.parse(r.result):null,resultAt:r.result_at,serverAccepted:true,deviceApplication:r.state==='applied'?'device_reported_applied':r.state==='failed'?'device_reported_failed':'unknown',userSeen:'unknown',userRequestEvidence:'agent_report_confirmation_required'};
 }
 async function submit(v,owner){
  if(!text(owner,200))throw new BridgeError('需要账户身份',401);
  // Retry still retrieves historical outcomes after expiry; never re-executes.
  const existing=await one('SELECT * FROM native_requests WHERE command_id=?',v.commandId);
  if(existing){if(existing.owner_id!==owner)throw new BridgeError('请求不存在',404);if(existing.request_hash!==await sha(canonical(v)))throw new BridgeError('同一commandId不可改变请求或设备',409);}
  else{
   const {body,permission}=validate(v),g=await grant(v.deviceId,permission);
   // Require canonical timestamps so retry hashing and the displayed payload match.
   if(canonical(body)!==canonical(v))throw new BridgeError('请使用标准UTC毫秒时间戳');
   await q(`INSERT OR IGNORE INTO native_requests(command_id,device_id,owner_id,request_hash,body,permission,grant_revision,state,accepted_at,expires_at) VALUES(?,?,?,?,?,?,?,'awaiting_confirmation',?,?)`,v.commandId,v.deviceId,owner,await sha(canonical(body)),canonical(body),permission,g.revision,time(),body.expiresAt).run();
  }
  const r=await row(v.commandId,owner);if(r.request_hash!==await sha(canonical(v)))throw new BridgeError('同一commandId不可改变请求',409);
  const value=await view(r);let approval=null;
  if(value.state==='awaiting_confirmation'){
   const token=crypto.randomUUID()+crypto.randomUUID();
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
  if(r.state!=='queued'||!r.approved_at)throw new BridgeError('请求未由用户确认',403);
  await q("UPDATE native_requests SET state='dispatching',attempt_id=?,claimed_at=? WHERE command_id=? AND state='queued' AND expires_at>? AND EXISTS(SELECT 1 FROM native_grants WHERE device_id=? AND revision=? AND expires_at>? AND EXISTS(SELECT 1 FROM devices WHERE id=native_grants.device_id AND revoked_at IS NULL))",v.attemptId,time(),r.command_id,time(),d.id,r.grant_revision,time()).run();
  const fresh=await row(r.command_id);if(fresh.state!=='dispatching'||fresh.attempt_id!==v.attemptId)throw new BridgeError('执行权已改变，请核对原请求',409);return view(fresh);
 }
 async function receipt(v,d){
  keys(v,['commandId','requestHash','attemptId','outcome','receipt']);await device(d.id);const r=await row(v.commandId);
  if(r.device_id!==d.id||r.request_hash!==v.requestHash||r.attempt_id!==v.attemptId||!r.approved_at||!['applied','failed','unknown'].includes(v.outcome)||!v.receipt||typeof v.receipt!=='object'||Array.isArray(v.receipt))throw new BridgeError('执行回执身份或结果无效',403);
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
 async function capabilities(){
  const rows=(await q('SELECT g.device_id,g.revision,g.body,g.expires_at,d.label FROM native_grants g JOIN devices d ON d.id=g.device_id WHERE d.revoked_at IS NULL AND g.expires_at>? ORDER BY g.device_id',time()).all()).results;
  return {readAt:time(),devices:rows.map(r=>({deviceId:r.device_id,label:r.label,revision:r.revision,capabilities:JSON.parse(r.body).capabilities,expiresAt:r.expires_at,confirmation:'chat_button',availability:'execution_requires_device_online_not_heartbeat_proof'}))};
 }
 return {capabilities,setGrant,readGrant,submit,approve,status,pending,claim,receipt};
}
