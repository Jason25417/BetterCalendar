import { BridgeError, iso } from './bridge.mjs';
const encode = v => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(v))));
const decode = v => JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(Uint8Array.from(atob(v), c => c.charCodeAt(0))));

// The append boundary freezes membership, not mutable session values. Receipts
// are the immutable evidence; sessions are the latest readable projection.
export function createTaskHistory(db, time, sessionView, taskApplication) {
  async function page(kind, input = {}) {
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
        if (cursor.version !== 1 || cursor.kind !== kind || cursor.from !== from || cursor.sessionId !== sessionId ||
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
    const nextCursor = hasMore ? encode({version:1,kind,from,before:upper,sessionId,maxRowid,at:last[column],id:last.id}) : null;
    return {schemaVersion:1,readAt:time(),from,before:upper,hasMore,nextCursor,
      ...(kind === 'commands' ? {sessionId,commands:entries,interpretation:'按服务端保存时间查询原始操作回执；保留未知字段。补传或开发期外部修改后从第一页重读。此接口不重放操作。'} :
        {sessions:entries,interpretation:'计时记录的最新状态，包含已结束记录；按开始时间排序。分页期间状态可能更新，这不是某一时刻的数据库快照。晚到补记或外部修改后从第一页重读。旧SwiftData历史尚未迁移。'})};
  }
  return {taskHistory:v=>page('sessions',v),readTaskCommands:v=>page('commands',v)};
}
