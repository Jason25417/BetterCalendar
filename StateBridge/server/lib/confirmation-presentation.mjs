import {BridgeError,canonical,sha} from './bridge.mjs';

const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Swift UUID.uuidString is uppercase; MCP UUID inputs may be lowercase.
// Compare UUID values, but never rewrite the persisted request/hash or fold
// opaque device IDs, revisions, cursors, or non-UUID directory keys.
const sameRecordId=(left,right)=>left===right||typeof left==='string'&&typeof right==='string'&&uuidPattern.test(left)&&uuidPattern.test(right)&&left.toLowerCase()===right.toLowerCase();

// Read only. The displayed before-values come from the designated device's
// pinned directory, never from an agent's claim about what used to be there.
export async function confirmationPresentation(core,value) {
 const request=value.request;
 const capabilities=await core.nativeCommands.capabilities();
 const device=capabilities.devices.find(d=>d.deviceId===value.deviceId);
 const display={version:1,deviceLabel:device?.label??value.deviceId,recordTitle:request.title??null,before:null,source:null};
 if(request.kind==='reminder'&&['update','cancel'].includes(request.action))return {...display,...await core.nativeCommands.reminderSnapshot(value.deviceId,request.reminderId,request.expectedRevision)};
 if(request.kind==='timer'&&request.action!=='start'){
  const state=await core.taskState(),session=state.sessions.find(s=>s.id===request.sessionId);
  if(!session||session.revision!==request.expectedRevision)throw new BridgeError('确认内容加载失败：原计时会话或版本已改变',409);
  display.recordTitle=session.title;display.before={status:session.status};display.source={readAt:state.readAt,revision:session.revision,freshness:'current'};return display;
 }
 if(request.kind!=='item'||request.action==='create')return display;
 let page=await core.readPoolRecords({deviceId:value.deviceId,includeTrash:true,limit:100});
 const seen=new Set();
 while(true){
  if(!page.complete)throw new BridgeError('确认内容加载失败：指定设备的事项快照未齐全；未发布确认、未执行，请先核对设备上传',409);
  const matches=page.records.filter(r=>sameRecordId(r.id,request.recordId));
  if(matches.length>1)throw new BridgeError('确认内容加载失败：事项UUID重复，无法唯一定位原事项；未发布确认、未执行',409);
  const record=matches[0];
  if(record){
   if(record.revision!==request.expectedRevision)throw new BridgeError('确认内容加载失败：事项版本已变化；未发布确认、未执行，请重读原事项',409);
   display.recordTitle=record.values.title;
   display.before=Object.fromEntries(Object.keys(request.patch??{}).map(key=>[key,record.values[key]]));
   if(Object.values(display.before).some(v=>v===undefined))throw new BridgeError('确认内容加载失败：修改前字段缺失，不能用空白代替未知',409);
   display.source={snapshotEventId:page.snapshotEventId,observedAt:page.observedAt,receivedAt:page.receivedAt,freshness:page.freshness,revision:record.revision};
   display.source.beforeHash=await sha(canonical(display.before));
   return display;
  }
  if(!page.hasMore)throw new BridgeError('确认内容加载失败：指定设备快照中找不到原事项；未发布确认、未执行',409);
  if(!page.nextCursor||seen.has(page.nextCursor))throw new BridgeError('确认内容加载失败：事项分页无法继续；未发布确认、未执行',409);
  seen.add(page.nextCursor);
  page=await core.readPoolRecords({deviceId:value.deviceId,includeTrash:true,limit:100,cursor:page.nextCursor});
 }
}
