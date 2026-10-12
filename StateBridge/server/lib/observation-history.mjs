import { BridgeError, iso } from "./bridge.mjs";
const encodeCursor = value => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value))));
const decodeCursor = value => JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(atob(value), c => c.charCodeAt(0))));

// Read-only access to the append-only evidence log. Unknown observation
// versions and fields are returned intact; no interpretation rewrites them.
export function createObservationHistory(db, time) {
  return async function readObservationHistory(input = {}) {
    if (typeof input.sourceKey !== "string" || !input.sourceKey.trim() || input.sourceKey.length > 150) throw new BridgeError("需要有效的 sourceKey");
    const from = input.from == null ? "1970-01-01T00:00:00.000Z" : iso(input.from);
    const before = input.before == null ? time() : iso(input.before);
    if (from > before) throw new BridgeError("查询开始时间不能晚于结束时间");
    const limit = input.limit ?? 30;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new BridgeError("每页需要 1 至 100 条");
    let cursor = null;
    if (input.cursor != null) {
      try {
        if (typeof input.cursor !== "string" || input.cursor.length > 2000) throw new Error();
        cursor = decodeCursor(input.cursor);
        if (cursor.version !== 1 || cursor.sourceKey !== input.sourceKey || cursor.from !== from || (input.before != null && cursor.before !== before) || typeof cursor.id !== "string" || cursor.id.length > 150 || iso(cursor.observedAt) !== cursor.observedAt || iso(cursor.before) !== cursor.before || iso(cursor.receivedThrough) !== cursor.receivedThrough || cursor.observedAt < from || cursor.observedAt > cursor.before) throw new Error();
      } catch { throw new BridgeError("历史游标无效或与查询范围不一致"); }
    }
    // Freeze the upper bound on page one so new uploads cannot shift pages.
    const upper = cursor?.before ?? before;
    const receivedThrough = cursor?.receivedThrough ?? time();
    const args = [input.sourceKey, from, upper, receivedThrough];
    let sql = "SELECT id,observed_at,received_at,body FROM observations WHERE source_key=? AND observed_at>=? AND observed_at<=? AND received_at<=?";
    if (cursor) { sql += " AND (observed_at>? OR (observed_at=? AND id>?))"; args.push(cursor.observedAt, cursor.observedAt, cursor.id); }
    sql += " ORDER BY observed_at,id LIMIT ?"; args.push(limit + 1);
    const rows = (await db.prepare(sql).bind(...args).all()).results;
    const page = [], observations = [];
    let bytes = 2048;
    for (const row of rows.slice(0, limit)) {
      const entry = { eventId: row.id, observedAt: row.observed_at, receivedAt: row.received_at, observation: JSON.parse(row.body) };
      const size = new TextEncoder().encode(JSON.stringify(entry)).length;
      if (bytes + size > 180 * 1024) {
        if (!page.length) throw new BridgeError("单条历史过大，原始记录已保留，请检查记录格式",413);
        break;
      }
      page.push(row); observations.push(entry); bytes += size;
    }
    const last = page.at(-1), hasMore = rows.length > page.length;
    const nextCursor = hasMore ? encodeCursor({ version: 1, sourceKey: input.sourceKey, from, before: upper, receivedThrough, observedAt: last.observed_at, id: last.id }) : null;
    return {
      schemaVersion: 1, readAt: time(), sourceKey: input.sourceKey, from, before: upper, asOfReceivedAt: receivedThrough,
      observations,
      hasMore, nextCursor,
      interpretation: "按发生时间排序的原始历史，不是实时状态或确认任务。晚到补传可能落在已读页之前；复核完整时间窗时从第一页重读。保留未知版本与字段，不修改原记录。",
    };
  };
}
