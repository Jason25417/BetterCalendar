import {BridgeError,iso} from './bridge.mjs';
export const reminderFields=['reminderId','body','sound','experiment'];
export const reminderPermissions=['reminder.read','reminder.schedule','reminder.update','reminder.cancel'];
const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
function keys(v,allowed){if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!allowed.includes(k)))throw new BridgeError('普通提醒字段无效');}
export function reminderQuery(q){
 keys(q,['reminderId','includeCancelled','limit','cursor']);
 if(q.reminderId!==undefined&&!uuid(q.reminderId)||q.includeCancelled!==undefined&&typeof q.includeCancelled!=='boolean'||q.limit!==undefined&&(!Number.isSafeInteger(q.limit)||q.limit<1||q.limit>20)||q.cursor!==undefined&&(typeof q.cursor!=='string'||q.cursor.length>2000))throw new BridgeError('提醒查询范围或分页无效');
}
export function validateReminder(v,at){
 if(!['read','schedule','update','cancel'].includes(v.action)||['recordId','patch','alarmId','entryDate'].some(k=>v[k]!==undefined))throw new BridgeError('普通提醒操作无效');
 if(v.action==='read'){
  if(['reminderId','expectedRevision','title','body','fireAt','sound','experiment'].some(k=>v[k]!==undefined))throw new BridgeError('提醒读取不可混入修改');
  reminderQuery(v.query??{});return 'reminder.read';
 }
 if(!uuid(v.reminderId)||v.query!==undefined)throw new BridgeError('提醒需要固定reminderId');
 if(v.action==='schedule'?v.expectedRevision!==undefined:typeof v.expectedRevision!=='string'||!/^[a-f0-9]{64}$/.test(v.expectedRevision))throw new BridgeError('提醒需要正确的原版本');
 if(v.action==='cancel'){
  if(['title','body','fireAt','sound','experiment'].some(k=>v[k]!==undefined))throw new BridgeError('取消不可混入新排程');
 }else if(typeof v.title!=='string'||!v.title.trim()||v.title.length>150||typeof v.body!=='string'||v.body.length>2000||typeof v.sound!=='boolean'||typeof v.experiment!=='boolean'||iso(v.fireAt)!==v.fireAt||v.fireAt<=at)throw new BridgeError('提醒需要完整标题/正文/未来时间/声音/实验标记');
 return 'reminder.'+v.action;
}
// A read-back is an authenticated device receipt, not an agent-provided before.
// Use the newest matching actual record, never search backwards for an older
// revision merely because it matches an obsolete proposal.
export function createReminderSnapshots(db,time){
 return async function snapshot(deviceId,reminderId,expectedRevision){
  const rows=(await db.prepare("SELECT * FROM native_requests WHERE device_id=? AND state='applied' AND permission IN ('reminder.read','reminder.schedule','reminder.update','reminder.cancel') ORDER BY result_at DESC,accepted_at DESC,command_id DESC LIMIT 100").bind(deviceId).all()).results;
  // Sort by device observation, not late network receipt. An applied child
  // revision also dominates its known parent even if the local clock moved.
  const observations=rows.map(row=>{const result=JSON.parse(row.result),request=JSON.parse(row.body);return {row,result,request,observedAt:result.readAt??result.checkedAt??null};});
  const parents=new Set(observations.filter(o=>o.row.permission!=='reminder.read'&&o.result.record?.reminderId?.toLowerCase()===reminderId.toLowerCase()).map(o=>o.request.expectedRevision).filter(Boolean));
  observations.sort((a,b)=>(Date.parse(b.observedAt)||0)-(Date.parse(a.observedAt)||0)||b.row.result_at.localeCompare(a.row.result_at));
  for(const {row,result,request,observedAt} of observations){
   const records=row.permission==='reminder.read'?result.records:[result.record];
   if(!Array.isArray(records))continue;
   const matching=records.filter(r=>r?.reminderId?.toLowerCase()===reminderId.toLowerCase());
   if(matching.length>1)throw new BridgeError('设备提醒回执包含重复身份，不能发布确认',409);
   const record=matching[0];
   if(!record){
    if(row.permission==='reminder.read'&&request.query?.reminderId?.toLowerCase()===reminderId.toLowerCase()&&result.complete===true&&!result.hasMore)throw new BridgeError('指定设备读回中找不到原提醒',409);
    continue;
   }
   if(parents.has(record.revision))continue;
   if(record.revision!==expectedRevision||record.cancelled===true)throw new BridgeError('提醒版本已改变或已经取消，需重新读取',409);
   const fields=['title','body','fireAt','sound','experiment'];
   if(typeof record.title!=='string'||typeof record.body!=='string'||typeof record.fireAt!=='string'||typeof record.sound!=='boolean'||typeof record.experiment!=='boolean')throw new BridgeError('提醒修改前内容未读全',409);
   return {recordTitle:record.title,before:Object.fromEntries(fields.map(k=>[k,record[k]])),source:{nativeCommandId:row.command_id,observedAt,receivedAt:row.result_at,revision:record.revision,freshness:!Number.isFinite(Date.parse(observedAt))?'unknown':Date.parse(time())-Date.parse(observedAt)>120000?'stale':'current',evidence:'authenticated_device_receipt'}};
  }
  throw new BridgeError('尚无原提醒的设备读回，请先read_native_reminders并等设备结果',409);
 };
}
