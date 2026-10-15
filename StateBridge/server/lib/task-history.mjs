import { BridgeError, iso } from './bridge.mjs';
const encode = v => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(v))));
const decode = v => JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(Uint8Array.from(atob(v), c => c.charCodeAt(0))));

// The append boundary freezes membership, not mutable session values. Receipts
// are the immutable evidence; sessions are the latest readable projection.
export function createTaskHistory(db, time, sessionView, taskApplication, readPoolRecords) {
  async function page(kind, input = {}) {
    const includeExperiments=input.includeExperiments??false;
    if(typeof includeExperiments!=='boolean')throw new BridgeError('includeExperiments需要布尔值');
    const from = input.from == null ? '1970-01-01T00:00:00.000Z' : iso(input.from);
    const before = input.before == null ? time() : iso(input.before);
    const limit = input.limit ?? 100;
    if (from > before) throw new BridgeError('查询开始时间不能晚于结束时间');
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new BridgeError('每页需要1至100条');
    const sessionId = kind === 'commands' ? input.sessionId ?? null : null;
    if (sessionId != null && (typeof sessionId !== 'string' || !sessionId.trim() || sessionId.length > 80)) throw new BridgeError('sessionId无效');
    let cursor;
    if (input.cursor != null) {
      try {
        if (typeof input.cursor !== 'string' || input.cursor.length > 2000) throw new Error();
        cursor = decode(input.cursor);
        if (cursor.version !== 1 || cursor.kind !== kind || (cursor.includeExperiments??false)!==includeExperiments || cursor.from !== from || cursor.sessionId !== sessionId ||
          (input.before != null && cursor.before !== before) || iso(cursor.before) !== cursor.before || iso(cursor.at) !== cursor.at ||
          cursor.at < from || cursor.at > cursor.before || typeof cursor.id !== 'string' || !cursor.id || cursor.id.length > 150 ||
          !Number.isSafeInteger(cursor.maxRowid) || cursor.maxRowid < 0) throw new Error();
      } catch { throw new BridgeError('计时历史游标无效或与查询范围不一致'); }
    }
    const table = kind === 'commands' ? 'commands' : 'sessions';
    const column = kind === 'commands' ? 'created_at' : 'started_at';
    const upper = cursor?.before ?? before;
    const maxRowid = cursor?.maxRowid ?? (await db.prepare(`SELECT COALESCE(MAX(rowid),0) n FROM ${table}`).first()).n;
    const args = [from, upper, maxRowid];
    let sql = `SELECT * FROM ${table} WHERE ${column}>=? AND ${column}<=? AND rowid<=?`;
    if (!includeExperiments) sql += kind==='sessions' ? ' AND experiment=0' : ' AND EXISTS(SELECT 1 FROM sessions s WHERE s.id=commands.session_id AND s.experiment=0)';
    if (sessionId != null) { sql += ' AND session_id=?'; args.push(sessionId); }
    if (cursor) { sql += ` AND (${column}<? OR (${column}=? AND id<?))`; args.push(cursor.at,cursor.at,cursor.id); }
    sql += ` ORDER BY ${column} DESC,id DESC LIMIT ?`; args.push(limit+1);
    const rows = (await db.prepare(sql).bind(...args).all()).results;
    const entries = [], accepted = []; let bytes = 2048;
    for (const row of rows.slice(0,limit)) {
      const entry = kind === 'commands' ? {commandId:row.id,sessionId:row.session_id,receivedAt:row.created_at,result:JSON.parse(row.result)} : sessionView(row);
      const size = new TextEncoder().encode(JSON.stringify(entry)).length;
      if (bytes+size > 128*1024) { if (!entries.length) throw new BridgeError('单条计时历史过大，原记录已保留',413); break; }
      entries.push(entry); accepted.push(row); bytes += size;
    }
    const last = accepted.at(-1), hasMore = rows.length > accepted.length;
    if(kind==='commands'){
      const receipts=await taskApplication.forCommands(entries.map(e=>e.commandId));
      for(const entry of entries){entry.deviceReceipts=receipts.get(entry.commandId) ?? [];entry.deviceApplication=entry.deviceReceipts.length?'device_reported_local_cache_persisted':'unknown';entry.screenVisible='unknown';entry.userSeen='unknown';}
    }
    const nextCursor = hasMore ? encode({version:1,kind,includeExperiments,from,before:upper,sessionId,maxRowid,at:last[column],id:last.id}) : null;
    return {schemaVersion:1,readAt:time(),from,before:upper,includeExperiments,hasMore,nextCursor,
      ...(kind === 'commands' ? {sessionId,commands:entries,interpretation:'按服务端保存时间查询原始操作回执；保留未知字段。补传或开发期外部修改后从第一页重读。此接口不重放操作。'} :
        {origin:'shared',sessions:entries,coverage:{legacyHistory:'query_origin_legacy_separately_same_window_no_automatic_sum'},interpretation:'共享计时的最新状态，不含旧SwiftData会话；空页不代表全天没有计时。用origin=legacy、同一时间窗和指定设备读旧历史副本，两组不要自动相加。分页期间状态可能更新，晚到补记或外部修改后从第一页重读。'})};
  }
  return {taskHistory:async(v={})=>{
    // Older installed tool schemas discard the new origin/deviceId fields.
    // Entry references and pinned page cursors returned by this server work
    // through the already-supported cursor argument; never replay a command.
    if(typeof v.cursor==='string'){
      if(v.cursor.startsWith('bc-legacy-entry-v1:')){
        let entry;try{if(v.cursor.length>1000)throw new Error();entry=decode(v.cursor.slice('bc-legacy-entry-v1:'.length));}catch{throw new BridgeError('旧历史入口游标无效');}
        if(typeof entry.deviceId!=='string'||!entry.deviceId||entry.deviceId.length>80||Object.keys(entry).some(k=>k!=='deviceId')||v.origin&&v.origin!=='legacy'||v.deviceId&&v.deviceId!==entry.deviceId)throw new BridgeError('旧历史入口身份不一致');
        v={...v,origin:'legacy',deviceId:entry.deviceId,cursor:undefined};
      }else{
        let pinned;try{pinned=decode(v.cursor);}catch{/* Normal shared-history validation handles invalid cursors. */}
        if(pinned?.filters?.recordType==='execution'){
          const p=pinned.filters;
          if(v.origin&&v.origin!=='legacy'||v.deviceId&&v.deviceId!==p.deviceId||v.from!==undefined&&v.from!==p.from||v.before!==undefined&&v.before!==p.before)throw new BridgeError('旧历史游标范围不一致');
          v={...v,origin:'legacy',deviceId:p.deviceId,from:p.from??undefined,before:p.before??undefined};
        }
      }
    }
    if(v.origin!==undefined&&!['shared','legacy'].includes(v.origin))throw new BridgeError('计时历史来源无效');
    if(v.origin!=='legacy')return page('sessions',v);
    if(typeof v.deviceId!=='string'||!v.deviceId.trim())throw new BridgeError('旧历史需要指定设备，不能自动合并双端');
    const result=await readPoolRecords({recordType:'execution',deviceId:v.deviceId,from:v.from,before:v.before,limit:v.limit,cursor:v.cursor});
    return {...result,origin:'legacy',from:v.from??null,before:v.before??null,authority:'device-swiftdata',sessions:result.records,interpretation:'这是指定设备SwiftData原会话的只读副本，不创建共享session或执行命令，不迁移/改写旧库。各设备视图分别读取；相同内容只作为可能重复线索，不自动相加或删除。按保存的开始时间筛选，不推算缺失活动。'};
  },readTaskCommands:v=>page('commands',v)};
}
