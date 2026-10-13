import { BridgeError, canonical, sha } from './bridge.mjs';

// Device attestations are independent of server acceptance and model reports.
// They attest a saved view cache, not a visible screen, Live Activity or a human.
export function createTaskApplication(db,time) {
  const q=(sql,...args)=>db.prepare(sql).bind(...args);
  async function offer(state,device,finishedRows) {
    const finished=finishedRows.slice(0,100);
    const versions=[...state.sessions,...finished].map(s=>({sessionId:s.id,revision:s.revision,status:s.status,commandId:s.commandId ?? s.lastCommandId}));
    const snapshotId=`task_snapshot_${crypto.randomUUID()}`,createdAt=time();
    const body={version:1,readAt:state.readAt,responseHash:await sha(canonical(state)),versions,
      activeComplete:!state.hasMore,finishedComplete:finishedRows.length<=100,
      evidenceLevel:'server_offered_not_device_applied'};
    await q('INSERT INTO research_log(call_id,kind,actor,created_at,body) VALUES(?,?,?,?,?)',snapshotId,'task_snapshot_offered',`device:${device.id}`,createdAt,JSON.stringify(body)).run();
    return {...state,applicationSnapshot:{id:snapshotId,finishedVersions:versions.filter(s=>s.status==='finished'),finishedComplete:body.finishedComplete}};
  }
  async function acknowledge(input,device) {
    const current=await q('SELECT scopes,revoked_at FROM devices WHERE id=?',device.id).first();
    if(!current||current.revoked_at||!JSON.parse(current.scopes).includes('user.context'))throw new BridgeError('设备应用回执权限已撤回',403);
    if(!Array.isArray(input.snapshotIds)||!input.snapshotIds.length||input.snapshotIds.length>10||new Set(input.snapshotIds).size!==input.snapshotIds.length)throw new BridgeError('每次需要1至10个不同的快照身份');
    const ops=[],accepted=[];
    for(const id of input.snapshotIds) {
      if(typeof id!=='string'||id.length>100)throw new BridgeError('快照身份无效');
      const row=await q("SELECT body FROM research_log WHERE call_id=? AND kind='task_snapshot_offered' AND actor=?",id,`device:${device.id}`).first();
      if(!row)throw new BridgeError('快照不存在或不属于此设备',403);
      const offered=JSON.parse(row.body);
      if(!offered.activeComplete)throw new BridgeError('未完整读取在途计时，不能确认应用',409);
      const receipt={version:1,snapshotId:id,deviceId:device.id,readAt:offered.readAt,responseHash:offered.responseHash,versions:offered.versions,
        finishedComplete:offered.finishedComplete,stage:'local_cache_persisted',
        evidenceLevel:'authenticated_device_report_not_screen_or_human_confirmation'};
      ops.push(q('INSERT OR IGNORE INTO research_log(call_id,kind,actor,created_at,body) VALUES(?,?,?,?,?)',`applied_${id}`,'task_snapshot_applied',`device:${device.id}`,time(),JSON.stringify(receipt)));
      accepted.push(id);
    }
    await db.batch(ops);
    return {accepted,recorded:true,stage:'local_cache_persisted',screenVisible:'unknown',userSeen:'unknown'};
  }
  async function forCommands(ids) {
    if(!ids.length)return new Map();
    const result=new Map();
    // Include device identity without copying title/health/credentials.
    const deviceRows=(await q(`SELECT body,created_at FROM research_log WHERE kind='task_snapshot_applied'
      AND EXISTS(SELECT 1 FROM json_each(body,'$.versions') j WHERE json_extract(j.value,'$.commandId') IN (${ids.map(()=>'?').join(',')}))`,...ids).all()).results;
    for(const row of deviceRows){const body=JSON.parse(row.body);for(const v of body.versions)if(ids.includes(v.commandId)){
      const prior=result.get(v.commandId) ?? [],entry={deviceId:body.deviceId,snapshotId:body.snapshotId,revision:v.revision,status:v.status,reportedAt:row.created_at,stage:body.stage};
      const i=prior.findIndex(p=>p.deviceId===body.deviceId);if(i<0)prior.push(entry);else if(prior[i].reportedAt<row.created_at)prior[i]=entry;result.set(v.commandId,prior);
    }}
    return result;
  }
  return {offer,acknowledge,forCommands};
}
