import {BridgeError,canonical,sha} from './bridge.mjs';

// Read only. The displayed before-values come from the designated device's
// pinned directory, never from an agent's claim about what used to be there.
export async function confirmationPresentation(core,value) {
 const request=value.request;
 const capabilities=await core.nativeCommands.capabilities();
 const device=capabilities.devices.find(d=>d.deviceId===value.deviceId);
 const display={version:1,deviceLabel:device?.label??value.deviceId,recordTitle:request.title??null,before:null,source:null};
 if(request.kind!=='item'||request.action==='create')return display;
 let page=await core.readPoolRecords({deviceId:value.deviceId,includeTrash:true,limit:100});
 const seen=new Set();
 while(true){
  if(!page.complete)throw new BridgeError('确认内容加载失败：指定设备的事项快照未齐全；未发布确认、未执行，请先核对设备上传',409);
  const record=page.records.find(r=>r.id===request.recordId);
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
