import {BridgeError,canonical} from './bridge.mjs';
const changed=r=>Number(r?.meta?.changes??r?.changes??0);

// One business command, one immutable recipient set, one durable OS submission
// intent per recipient. Does not create another execution request or permission.
export function createApprovalFanout(db,time,{canReview,requestView}){
 const q=(sql,...args)=>db.prepare(sql).bind(...args),one=(sql,...args)=>q(sql,...args).first();
 const active="EXISTS(SELECT 1 FROM native_requests n JOIN native_grants g ON g.device_id=n.device_id JOIN devices td ON td.id=n.device_id WHERE n.command_id=? AND n.request_hash=? AND n.state='awaiting_confirmation' AND n.expires_at>? AND g.revision=n.grant_revision AND g.expires_at>? AND td.revoked_at IS NULL AND EXISTS(SELECT 1 FROM json_each(g.body,'$.capabilities') WHERE value=n.permission))";
 async function route(id){return one('SELECT * FROM native_approval_notification_routes WHERE command_id=?',id);}
 async function claim(r,d,p){
  const policy=JSON.parse(p.body),at=time();
  // Only independently opted-in reviewers are eligible. The original target
  // needs no new cross-device scope to receive its own approval notification.
  const ids=[r.device_id];
  for(const reviewer of policy.reviewers)if(await canReview(reviewer.deviceId))ids.push(reviewer.deviceId);
  const recipients=[...new Set(ids)].sort();
  await db.batch([
   q(`INSERT OR IGNORE INTO native_approval_notification_routes(command_id,request_hash,policy_revision,device_ids,created_at) SELECT ?,?,?,?,? WHERE ${active} AND NOT EXISTS(SELECT 1 FROM native_approval_notifications WHERE command_id=?)`,r.command_id,r.request_hash,p.revision,canonical(recipients),at,r.command_id,r.request_hash,at,at,r.command_id),
   q('INSERT INTO research_log(call_id,kind,actor,created_at,body) SELECT ?,?,?,?,? WHERE changes()>0',`approval_route_${crypto.randomUUID()}`,'approval_notification_route_frozen',`device:${d.id}`,at,canonical({version:1,commandId:r.command_id,requestHash:r.request_hash,mode:'all_reviewers',policyRevision:p.revision,deviceIds:recipients}))
  ]);
  const plan=await route(r.command_id);
  if(!plan)return null; // A concurrent legacy single-device route won.
  if(plan.request_hash!==r.request_hash)throw new BridgeError('原通知身份冲突',409);
  const destinations=JSON.parse(plan.device_ids);
  const access=destinations.includes(d.id)&&(d.id===r.device_id||await canReview(d.id));
  if(!access)return {version:1,commandId:r.command_id,requestHash:r.request_hash,maySubmit:false,deviceId:null,claimId:null,reason:'not_frozen_recipient'};
  await q(`INSERT OR IGNORE INTO native_approval_notification_deliveries(command_id,request_hash,device_id,policy_revision,claim_id,state,updated_at) SELECT ?,?,?,?,?,'routed',? WHERE ${active}`,r.command_id,r.request_hash,d.id,plan.policy_revision,crypto.randomUUID(),at,r.command_id,r.request_hash,at,at).run();
  const begin=changed(await q(`UPDATE native_approval_notification_deliveries SET state='reserved',updated_at=? WHERE command_id=? AND device_id=? AND state='routed' AND ${active}`,at,r.command_id,d.id,r.command_id,r.request_hash,at,at).run())>0;
  const saved=await one('SELECT * FROM native_approval_notification_deliveries WHERE command_id=? AND device_id=?',r.command_id,d.id);
  if(!saved)return {version:1,commandId:r.command_id,requestHash:r.request_hash,maySubmit:false,reason:'no_longer_pending',state:(await requestView(await one('SELECT * FROM native_requests WHERE command_id=?',r.command_id))).state};
  return {version:1,commandId:r.command_id,requestHash:r.request_hash,deviceId:d.id,policyRevision:plan.policy_revision,claimId:saved.claim_id,state:saved.state,maySubmit:saved.state==='reserved',beginSubmission:begin,reason:'each_authorized_device_once',systemSubmittedAt:saved.system_submitted_at??null,clickedAt:saved.clicked_at??null};
 }
 return {route,claim};
}
