import {BridgeError,canonical,sha} from './bridge.mjs';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const changed=r=>Number(r?.meta?.changes??r?.changes??0);
function keys(v,allowed){if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!allowed.includes(k)))throw new BridgeError('审批路由字段无效');}
// Single personal-account instance. Cross-device review is a separate human
// opt-in tied to the existing device grant; models cannot configure it.
export function createApprovalRouting(db,time,{device,grant,requestView}){
 const q=(sql,...args)=>db.prepare(sql).bind(...args),one=(sql,...args)=>q(sql,...args).first();
 async function rawPolicy(){return await one("SELECT * FROM native_approval_policy WHERE id='personal'")??{revision:0,body:canonical({primaryDeviceId:null,reviewers:[]}),last_request_hash:null};}
 async function canReview(id){
  const reviewer=JSON.parse((await rawPolicy()).body).reviewers.find(r=>r.deviceId===id);if(!reviewer)return false;
  await device(id);const g=await one('SELECT * FROM native_grants WHERE device_id=?',id);
  return !!g&&g.revision===reviewer.grantRevision&&g.expires_at===reviewer.expiresAt&&g.expires_at>time();
 }
 async function readiness(){
  const rows=(await q("SELECT d.id,d.label,s.body,s.observed_at,s.received_at FROM devices d JOIN native_grants g ON g.device_id=d.id LEFT JOIN states s ON s.source_key=d.id||':device.status' WHERE d.revoked_at IS NULL AND g.expires_at>? AND json_array_length(g.body,'$.capabilities')>0",time()).all()).results;
  const at=Date.parse(time()),maxAgeSeconds=900;
  const devices=rows.map(r=>{let value;try{value=JSON.parse(r.body).value;}catch{}
   const age=at-Date.parse(r.observed_at),receivedAge=at-Date.parse(r.received_at);
   const ready=value?.approvalNotifications?.routingProtocol===1&&age>=-30000&&age<=maxAgeSeconds*1000&&receivedAge>=0&&receivedAge<=maxAgeSeconds*1000;
   return {deviceId:r.id,label:r.label,ready,notificationsEnabled:value?.approvalNotifications?.enabled===true,systemAuthorization:value?.approvalNotifications?.systemAuthorization??'unknown',reason:ready?'supported_recent_report':!r.body?'missing_status':value?.approvalNotifications?.routingProtocol!==1?'update_required':'stale_status'};
  });return {ready:devices.length>0&&devices.every(d=>d.ready),maxAgeSeconds,devices};
 }
 async function runtimeCompatible(policy){
  // Protocol support is a capability, not an activity heartbeat. An offline
  // peer must not stop an online selected device from alerting. A newly
  // reported legacy version still disables a second alert; never fail over.
  const rows=(await q("SELECT d.id,s.body FROM devices d JOIN native_grants g ON g.device_id=d.id LEFT JOIN states s ON s.source_key=d.id||':device.status' WHERE d.revoked_at IS NULL AND g.expires_at>? AND json_array_length(g.body,'$.capabilities')>0",time()).all()).results;
  return rows.every(r=>{let value;try{value=JSON.parse(r.body).value;}catch{}
   return value?.approvalNotifications?value.approvalNotifications.routingProtocol===1:(policy.routingDevices??[]).includes(r.id);
  });
 }
 async function read(d){await device(d.id);const row=await rawPolicy(),policy=JSON.parse(row.body);return {version:1,revision:row.revision,primaryDeviceId:policy.primaryDeviceId,reviewOtherDevices:await canReview(d.id),notificationFallback:'none',policyAppliesTo:'requests_accepted_after_setting_change',delivery:'local_poll_while_app_runs',remotePush:false,routingReadiness:await readiness()};}
 async function configure(v,d){
  keys(v,['expectedRevision','reviewOtherDevices','primaryHere']);await device(d.id);
  if(!Number.isSafeInteger(v.expectedRevision)||v.expectedRevision<0||v.reviewOtherDevices===undefined&&v.primaryHere===undefined||['reviewOtherDevices','primaryHere'].some(k=>v[k]!==undefined&&typeof v[k]!=='boolean'))throw new BridgeError('审批设置版本或明确选择无效');
  const hash=await sha(canonical({deviceId:d.id,...v})),row=await rawPolicy();
  if(row.last_request_hash===hash)return read(d);if(row.revision!==v.expectedRevision)throw new BridgeError('审批设置已变化，请刷新后选择',409);
  const policy=JSON.parse(row.body),reviewers=policy.reviewers.filter(r=>r.deviceId!==d.id);
  if(v.reviewOtherDevices===true){const g=await grant(d.id);reviewers.push({deviceId:d.id,grantRevision:g.revision,expiresAt:g.expires_at});}
  else if(v.reviewOtherDevices===undefined)reviewers.push(...policy.reviewers.filter(r=>r.deviceId===d.id));
  policy.reviewers=reviewers;
  if(v.primaryHere===true){if(!reviewers.some(r=>r.deviceId===d.id)||v.reviewOtherDevices!==true&&!await canReview(d.id))throw new BridgeError('请先明确允许本机跨设备核对审批，再选主要通知设备',403);const readinessReport=await readiness();if(!readinessReport.ready)throw new BridgeError('参与设备尚未全部报告新版审批协议，请更新并打开后重试',409);const self=readinessReport.devices.find(x=>x.deviceId===d.id);if(!self?.notificationsEnabled||!['authorized','provisional'].includes(self.systemAuthorization))throw new BridgeError('请先在这台设备明确开启审批通知并上传系统授权状态',409);policy.primaryDeviceId=d.id;policy.routingDevices=readinessReport.devices.map(x=>x.deviceId);}
  else if(v.primaryHere===false&&policy.primaryDeviceId===d.id||v.reviewOtherDevices===false&&policy.primaryDeviceId===d.id)policy.primaryDeviceId=null;
  const at=time(),revision=row.revision+1;
  const results=await db.batch([
   q("INSERT INTO native_approval_policy(id,revision,body,last_request_hash,updated_at) VALUES('personal',?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,body=excluded.body,last_request_hash=excluded.last_request_hash,updated_at=excluded.updated_at WHERE native_approval_policy.revision=?",revision,canonical(policy),hash,at,row.revision),
   q('INSERT INTO research_log(call_id,kind,actor,created_at,body) SELECT ?,?,?,?,? WHERE changes()>0',`approval_policy_${crypto.randomUUID()}`,'approval_policy_changed',`device:${d.id}`,at,canonical({version:1,revision,deviceId:d.id,primaryDeviceId:policy.primaryDeviceId,reviewOtherDevices:reviewers.some(r=>r.deviceId===d.id),source:'explicit_device_settings',userGesture:'transport_report_not_independent_observation'}))
  ]);if(!changed(results[0]))throw new BridgeError('审批设置版本冲突',409);return read(d);
 }
 async function allowed(r,d){await device(d.id);if(!r)throw new BridgeError('请求不存在',404);if(r.device_id!==d.id&&!await canReview(d.id))throw new BridgeError('本机未单独允许跨设备查看/确认审批',403);}
 function decisionGuard(id,grantRevision,policyRevision){return {
  sql:"EXISTS(SELECT 1 FROM native_approval_policy p,json_each(p.body,'$.reviewers') e JOIN native_grants rg ON rg.device_id=json_extract(e.value,'$.deviceId') JOIN devices rd ON rd.id=rg.device_id WHERE p.id='personal' AND p.revision=? AND rg.device_id=? AND rg.revision=? AND rg.revision=json_extract(e.value,'$.grantRevision') AND rg.expires_at=json_extract(e.value,'$.expiresAt') AND rg.expires_at>? AND rd.revoked_at IS NULL)",
  args:[policyRevision,id,grantRevision,time()]
 };}
 async function claim(v,d){
  keys(v,['commandId','requestHash']);await device(d.id);if(typeof v.commandId!=='string'||!uuid.test(v.commandId)||typeof v.requestHash!=='string')throw new BridgeError('通知请求身份无效');
  const r=await one('SELECT * FROM native_requests WHERE command_id=?',v.commandId);await allowed(r,d);if(r.request_hash!==v.requestHash)throw new BridgeError('通知请求哈希不匹配',409);
  const value=await requestView(r);if(value.state!=='awaiting_confirmation')return {version:1,commandId:r.command_id,requestHash:r.request_hash,maySubmit:false,reason:'not_pending',state:value.state};
  const p=await rawPolicy(),policy=JSON.parse(p.body),target=policy.primaryDeviceId&&r.accepted_at>=p.updated_at?policy.primaryDeviceId:r.device_id;
  // Freeze one destination, even across policy edits/restarts. No failover or
  // lease stealing: another device cannot create a duplicate interruption.
  await q("INSERT OR IGNORE INTO native_approval_notifications(command_id,request_hash,device_id,policy_revision,claim_id,state,updated_at) SELECT ?,?,?,?,?,'routed',? WHERE EXISTS(SELECT 1 FROM native_requests n JOIN native_grants g ON g.device_id=n.device_id JOIN devices td ON td.id=n.device_id WHERE n.command_id=? AND n.request_hash=? AND n.state='awaiting_confirmation' AND n.expires_at>? AND g.revision=n.grant_revision AND g.expires_at>? AND td.revoked_at IS NULL AND EXISTS(SELECT 1 FROM json_each(g.body,'$.capabilities') WHERE value=n.permission))",r.command_id,r.request_hash,target,p.revision,crypto.randomUUID(),time(),r.command_id,r.request_hash,time(),time()).run();
  let saved=await one('SELECT * FROM native_approval_notifications WHERE command_id=?',r.command_id);
  if(!saved)return {version:1,commandId:r.command_id,requestHash:r.request_hash,maySubmit:false,reason:'no_longer_pending',state:(await requestView(await one('SELECT * FROM native_requests WHERE command_id=?',r.command_id))).state};
  if(saved.request_hash!==r.request_hash)throw new BridgeError('原通知身份冲突',409);
  // A newly reported legacy participant cannot cause a second alert on the primary.
  // Freeze as unknown rather than rerouting or retrying later after an upgrade.
  if(policy.primaryDeviceId&&target===policy.primaryDeviceId&&!await runtimeCompatible(policy))await q("UPDATE native_approval_notifications SET state='unknown',updated_at=? WHERE command_id=? AND state='routed'",time(),r.command_id).run();
  saved=await one('SELECT * FROM native_approval_notifications WHERE command_id=?',r.command_id);
  const access=saved.device_id===d.id&&(r.device_id===d.id||await canReview(d.id));
  const begin=access?changed(await q("UPDATE native_approval_notifications SET state='reserved',updated_at=? WHERE command_id=? AND state='routed'",time(),r.command_id).run())>0:false;
  if(begin)saved=await one('SELECT * FROM native_approval_notifications WHERE command_id=?',r.command_id);
  return {version:1,commandId:r.command_id,requestHash:r.request_hash,deviceId:saved.device_id,policyRevision:saved.policy_revision,claimId:access?saved.claim_id:null,state:saved.state,maySubmit:access&&saved.state==='reserved',beginSubmission:begin,reason:access?'selected_device':'other_device_only',systemSubmittedAt:saved.system_submitted_at??null,clickedAt:saved.clicked_at??null};
 }
 async function receipt(v,d){
  keys(v,['commandId','requestHash','claimId','state']);await device(d.id);if(!['system_submitted','unknown','failed','clicked'].includes(v.state))throw new BridgeError('通知回执状态无效');
  const row=await one('SELECT * FROM native_approval_notifications WHERE command_id=?',v.commandId);if(!row||row.device_id!==d.id||row.request_hash!==v.requestHash||row.claim_id!==v.claimId)throw new BridgeError('通知回执绑定无效',403);
  await allowed(await one('SELECT * FROM native_requests WHERE command_id=?',v.commandId),d);const at=time();
  // Never downgrade submitted/clicked evidence with a late failure. Unknown
  // is not retry authorization; the client must retain its submission intent.
  const prior=v.state==='clicked'?['reserved','unknown','failed','system_submitted']:v.state==='system_submitted'?['reserved','unknown']:['reserved'];
  await db.batch([
   q(`UPDATE native_approval_notifications SET state=?,updated_at=?,system_submitted_at=CASE WHEN ?='system_submitted' THEN COALESCE(system_submitted_at,?) ELSE system_submitted_at END,clicked_at=CASE WHEN ?='clicked' THEN COALESCE(clicked_at,?) ELSE clicked_at END WHERE command_id=? AND claim_id=? AND state IN (${prior.map(()=>'?').join(',')})`,v.state,at,v.state,at,v.state,at,v.commandId,v.claimId,...prior),
   q('INSERT INTO research_log(call_id,kind,actor,created_at,body) SELECT ?,?,?,?,? WHERE changes()>0',`approval_notice_${crypto.randomUUID()}`,'approval_notification_receipt',`device:${d.id}`,at,canonical({version:1,commandId:v.commandId,requestHash:v.requestHash,state:v.state,evidence:'device_report',userSeen:'unknown'}))
  ]);
  const saved=await one('SELECT * FROM native_approval_notifications WHERE command_id=?',v.commandId);return {version:1,commandId:v.commandId,state:saved.state,systemSubmittedAt:saved.system_submitted_at??null,clickedAt:saved.clicked_at??null,userSeen:'unknown'};
 }
 return {read,configure,canReview,allowed,decisionGuard,claim,receipt};
}
