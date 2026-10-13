import { BridgeError, canonical } from './bridge.mjs';
import { sourceView } from './state-view.mjs';
const hex = bytes => [...bytes].map(b => b.toString(16).padStart(2,'0')).join('');
const hash = async bytes => hex(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)));
const encode = v => btoa(JSON.stringify(v));
const decode = v => JSON.parse(atob(v));
export function createPoolRecords(db,time){
 const one=(sql,...args)=>db.prepare(sql).bind(...args).first();
 const all=async(sql,...args)=>(await db.prepare(sql).bind(...args).all()).results;
 return async function readPoolRecords(input={}){
  const recordType=input.recordType??'item';
  const limit=input.limit??50,filters={deviceId:input.deviceId??null,zone:input.zone??null,status:input.status??null,includeTrash:input.includeTrash??false,
    ...(recordType==='execution'?{recordType,from:input.from==null?null:input.from,before:input.before==null?null:input.before}:{})};
  if(!['item','execution'].includes(recordType)||recordType==='execution'&&(filters.zone!==null||filters.status!==null||filters.includeTrash))throw new BridgeError('历史计时只读，不能混用事项筛选');
  if(recordType==='execution'){
    for(const k of ['from','before'])if(filters[k]!==null&& (typeof filters[k]!=='string'||!Number.isFinite(Date.parse(filters[k]))))throw new BridgeError('历史计时时间范围无效');
    if(filters.from&&filters.before&&Date.parse(filters.from)>Date.parse(filters.before))throw new BridgeError('历史计时范围逆序');
  }
  if(!Number.isSafeInteger(limit)||limit<1||limit>100||
    (filters.deviceId!==null&&(typeof filters.deviceId!=='string'||!filters.deviceId.length||filters.deviceId.length>80))||
    (filters.zone!==null&&!['longterm','todo'].includes(filters.zone))||
    (filters.status!==null&&!['active','done','shelved'].includes(filters.status))||typeof filters.includeTrash!=='boolean')throw new BridgeError('事项目录筛选无效');
  const readAt=time();
  const latest=(await all("SELECT s.body FROM states s JOIN devices d ON d.id=s.device_id WHERE s.source_key=s.device_id||':bc.pool' AND d.revoked_at IS NULL ORDER BY s.observed_at DESC,s.received_at DESC,s.source_key"))
    .map(r=>JSON.parse(r.body));
  const devices=latest.map(r=>{const s=sourceView(r,`${r.deviceId}:bc.pool`,readAt);return {deviceId:r.deviceId,availability:s.availability,freshness:s.freshness,observedAt:r.observedAt,receivedAt:r.receivedAt,contentHash:r.value?.contentHash??null};});
  let observation,offset=0,pinned=false;
  if(input.cursor!=null){
   try{
    if(typeof input.cursor!=='string'||input.cursor.length>2000)throw new Error();
    const c=decode(input.cursor);
    if(c.version!==1||canonical(c.filters)!==canonical(filters)||typeof c.eventId!=='string'||c.eventId.length>150||!Number.isSafeInteger(c.offset)||c.offset<0)throw new Error();
    const row=await one("SELECT o.body FROM observations o JOIN devices d ON d.id=o.device_id WHERE o.id=? AND d.revoked_at IS NULL",c.eventId);
    if(!row)throw new Error();observation=JSON.parse(row.body);offset=c.offset;pinned=true;
   }catch{throw new BridgeError('事项目录游标无效或筛选不一致');}
  }else observation=latest.find(r=>filters.deviceId===null||r.deviceId===filters.deviceId);
  if(!observation)return {schemaVersion:1,authority:'device-swiftdata',readAt,availability:'not_received',freshness:'unknown',complete:false,records:[],hasMore:false,nextCursor:null,devices};
  if(observation.source!=='bc.pool'||(filters.deviceId&&observation.deviceId!==filters.deviceId))throw new BridgeError('目录来源不匹配');
  const view=sourceView(observation,`${observation.deviceId}:bc.pool`,readAt);
  const metadata={schemaVersion:1,authority:'device-swiftdata',readAt,sourceDeviceId:observation.deviceId,snapshotEventId:observation.eventId,
   observedAt:observation.observedAt,receivedAt:observation.receivedAt,freshness:view.freshness,availability:view.availability,usableForCurrentState:view.usableForCurrentState,
   devices,deviceViewsDiffer:new Set(devices.filter(d=>d.contentHash).map(d=>d.contentHash)).size>1,pinnedSnapshot:pinned,deviceViewsDifferBasis:'whole_snapshot_including_legacy_history_not_proof_of_item_conflict',
   interpretation:'这是设备读取的SwiftData目录副本，不是另一套事项真相。不同设备目录不同可能是同步延迟；不自动合并或覆盖。分页固定这一份快照，旧快照不能冒充当前状态。'};
  if(view.availability!=='available')return {...metadata,complete:false,records:[],hasMore:false,nextCursor:null};
  const m=observation.value;
  if(m?.formatVersion!==1||m.authority!=='swiftdata'||!/^[a-f0-9]{64}$/.test(m.contentHash)||
    !Number.isSafeInteger(m.recordCount)||m.recordCount<0||!Array.isArray(m.chunkEventIds)||!m.chunkEventIds.length||m.chunkEventIds.length>274||
    m.chunkEventIds.some(id=>typeof id!=='string'||!id.length||id.length>150)||new Set(m.chunkEventIds).size!==m.chunkEventIds.length)throw new BridgeError('目录清单版本或内容无效；原始记录保留');
  const rows=[];
  for(let i=0;i<m.chunkEventIds.length;i+=40){const ids=m.chunkEventIds.slice(i,i+40);rows.push(...await all(`SELECT id,body FROM observations WHERE id IN (${ids.map(()=>'?').join(',')})`,...ids));}
  const byId=new Map(rows.map(r=>[r.id,JSON.parse(r.body)])),parts=[];let size=0;
  for(const [index,id] of m.chunkEventIds.entries()){
   const chunk=byId.get(id),v=chunk?.value;
   if(chunk?.deviceId!==observation.deviceId||chunk?.source!=='bc.pool.chunk'||v?.formatVersion!==1||v.contentHash!==m.contentHash||v.index!==index||typeof v.bytes!=='string'||v.bytes.length>40960)throw new BridgeError('目录分片尚未齐全或不匹配，请稍后重读',409);
   let bytes;try{bytes=Uint8Array.from(atob(v.bytes),c=>c.charCodeAt(0));}catch{throw new BridgeError('目录分片损坏，原始记录保留');}
   size+=bytes.length;if(size>8*1024*1024)throw new BridgeError('目录超过读取上限',413);parts.push(bytes);
  }
  const bytes=new Uint8Array(size);let at=0;for(const p of parts){bytes.set(p,at);at+=p.length;}
  if(await hash(bytes)!==m.contentHash)throw new BridgeError('目录校验失败，原始记录保留');
  let payload;try{payload=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw new BridgeError('目录格式损坏，原始记录保留');}
  if(payload.formatVersion!==1||payload.authority!=='swiftdata'||payload.dateUnit!=='unix-milliseconds'||!Array.isArray(payload.records)||payload.records.length!==m.recordCount||
   payload.records.some(r=>typeof r.id!=='string'||!r.id||r.values?.id!==r.id||!/^[a-f0-9]{64}$/.test(r.revision)||typeof r.values.isInTrash!=='boolean')||
   new Set(payload.records.map(r=>r.id)).size!==payload.records.length)throw new BridgeError('目录身份、版本或数量不一致，原始记录保留');
  if(recordType==='execution'&&!Array.isArray(payload.executionSessions))return {...metadata,recordType,availability:'not_supported_by_device_snapshot',complete:false,records:[],hasMore:false,nextCursor:null,interpretation:'该设备目录来自旧版采集器，未包含SwiftData计时历史；不是没有记录。'};
  const executions=payload.executionSessions??[];
  if(recordType==='execution'&&(!Number.isSafeInteger(m.executionSessionCount)||executions.length!==m.executionSessionCount||
    executions.some(r=>typeof r.id!=='string'||!/^legacy:[a-f0-9]{64}$/.test(r.id)||r.values?.id!==r.id||r.values.origin!=='swiftdata_execution_session'||typeof r.values.title!=='string'||!Number.isFinite(r.values.start)||r.values.end!==null&&!Number.isFinite(r.values.end)||r.values.commandId!==null||!/^[a-f0-9]{64}$/.test(r.revision))||new Set(executions.map(r=>r.id)).size!==executions.length))throw new BridgeError('旧计时历史数量、身份或版本不一致，原库保留');
  const selected=recordType==='execution'?executions.filter(r=>(filters.from===null||r.values.start>=Date.parse(filters.from))&&(filters.before===null||r.values.start<=Date.parse(filters.before))):payload.records.filter(r=>(filters.includeTrash||!r.values.isInTrash)&&(filters.zone===null||r.values.zone===filters.zone)&&(filters.status===null||r.values.status===filters.status));
  if(offset>selected.length)throw new BridgeError('目录游标超出范围');
  const records=[];let budget=0;
  for(const record of selected.slice(offset,offset+limit)){
   const length=new TextEncoder().encode(JSON.stringify(record)).length;
   if(records.length&&budget+length>160*1024)break;records.push(record);budget+=length;
  }
  const next=offset+records.length,hasMore=next<selected.length;
  return {...metadata,recordType,contentHash:m.contentHash,complete:true,totalRecordCount:recordType==='execution'?executions.length:m.recordCount,matchedRecordCount:selected.length,
   records,byteBudgetExceeded:budget>160*1024,hasMore,nextCursor:hasMore?encode({version:1,eventId:observation.eventId,offset:next,filters}):null};
 };
}
