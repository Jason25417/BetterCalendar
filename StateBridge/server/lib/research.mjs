import { BridgeError, canonical, sha } from './bridge.mjs';

// No tool bodies, credentials, callback URLs or private model reasoning here.
// The local recorder resolves references to the existing authoritative records.
const argumentKeys = ['origin','recordType','afterId','limit','throughId','batchId','includeValues','sourceKeys','sourceKey','from','before','cursor','deviceId','zone','status','includeTrash','commandId','action','sessionId','expectedRevision','occurredAt','attemptId','requestHash','outcome','grantRevision','provenance','relatedRecordId','id','kind','assertion','confidence','basis','expiresAt','supersedes'];
export function safeArguments(args) {
  const clean=Object.fromEntries(argumentKeys.filter(k => args[k] !== undefined).map(k => [k,args[k]]));
  if(Array.isArray(args.observations))clean.observations=args.observations.map(o=>({eventId:o.eventId,source:o.source,sequence:o.sequence,observedAt:o.observedAt}));
  if(Array.isArray(args.snapshotIds))clean.snapshotIds=args.snapshotIds;
  // Bodies are deliberately excluded. Remove recognizable credential strings
  // even if accidentally placed in a cursor/basis field.
  const redact=value=>typeof value==='string'?value.replace(/Bearer\s+\S+|whsec_[\w+/=-]+|sk-[\w-]{12,}/gi,'[redacted]'):Array.isArray(value)?value.map(redact):value&&typeof value==='object'?Object.fromEntries(Object.entries(value).map(([k,v])=>[k,redact(v)])):value;
  if(args.confirmation)clean.confirmation={transport:args.confirmation.transport,action:args.confirmation.action,confirmed:args.confirmation.confirmed,
    ...(args.confirmation.action==='cancel'&&args.confirmation.source==='host_response'?{source:'host_response',userGesture:'unknown',cause:'unknown'}:{})};
  return redact(clean);
}
function references(value) {
  return {
    observationIds: [...new Set([...(value.sources ?? []).map(s=>s.eventId), ...(value.changes ?? []).map(c=>c.observation?.eventId), ...(value.observations ?? []).map(o=>o.eventId)].filter(Boolean))],
    changeIds: (value.changes ?? []).map(c=>c.id),
    nativeCommandIds: [...new Set([value.nativeCommandId,...(value.commands ?? []).map(c=>c.nativeCommandId)].filter(Boolean))],
    commandIds: [...new Set([value.nativeCommandId ? null : value.commandId,...(value.commands ?? []).filter(c=>!c.nativeCommandId).map(c=>c.commandId)].filter(Boolean))],
    ingestion: {accepted:value.accepted ?? null,ignored:value.ignored ?? null,receivedAt:value.receivedAt ?? null},
    delivery: {batchId:value.batchId ?? null,delivered:value.delivered ?? null,decision:value.decision ?? null},
    sessionVersions: [...(value.sessions ?? []),...(value.id && value.revision ? [value] : [])].map(s=>({id:s.id,revision:s.revision})),
    snapshotEventId: value.snapshotEventId ?? null,
    noteIds: (value.notes ?? []).map(n=>n.id),
    sourceMetadata: (value.sources ?? []).map(s=>({sourceKey:s.sourceKey,eventId:s.eventId,assertion:s.assertion,observedAt:s.observedAt,receivedAt:s.receivedAt,expiresAt:s.expiresAt,freshness:s.freshness,availability:s.availability})),
    coverage: value.coverage ?? value.result?.coverage ?? null,
    pagination: {hasMore:value.hasMore ?? value.result?.hasMore ?? null,nextCursor:value.nextCursor ?? value.result?.nextCursor ?? null,throughId:value.throughId ?? null,valuesIncluded:value.valuesIncluded ?? null},
    saved: value.saved ?? null,
    interpretation: 'References are evidence locations, not proof that the agent understood them. Raw tool response is not copied to a new cloud store.',
  };
}

export function createResearch(db,time) {
  const q=(sql,...args)=>db.prepare(sql).bind(...args);
  const one=(sql,...args)=>q(sql,...args).first();
  async function append(kind,batchId,body,actor=null) {
    const callId=`research_${crypto.randomUUID()}`;
    await q('INSERT INTO research_log(call_id,kind,batch_id,actor,created_at,body) VALUES(?,?,?,?,?,?)',callId,kind,batchId,actor,time(),JSON.stringify({version:1,...body})).run();
    return callId;
  }
  async function invoke(name,args,actor,operation) {
    // Persist intent before execution. If recording fails, do not execute.
    const startedAt=time(),batchId=args.batchId ?? null;
    const callId=await append('call_started',batchId,{tool:name,arguments:safeArguments(args),startedAt,permission:{transport:'authenticated_owner_or_scoped_device',operation:'pending_validation',userIntent:name==='task_command'?'declared_user_provenance_not_independent_attestation':null}},actor);
    let value;
    try { value=await operation(); }
    catch(error) {
      await append('call_failed',batchId,{callId,tool:name,finishedAt:time(),error:{status:error instanceof BridgeError?error.status:500,category:error instanceof BridgeError?'request':'internal'},permission:error?.status===403?'denied':'not_proven',retryCommandId:args.commandId ?? null},actor);
      throw error;
    }
    // Failure here propagates: action may have succeeded; retry same commandId.
    const responseHash=await sha(canonical(value));
    await append('call_returned',batchId,{callId,tool:name,arguments:safeArguments(args),startedAt,finishedAt:time(),responseHash,references:references(value),deviceApplication:'unknown_unless_separate_device_receipt'},actor);
    return {...value,research:{callId,responseHash,recorded:true}};
  }
  async function read(input={}) {
    const after=input.afterId ?? 0,limit=input.limit ?? 30;
    if(!Number.isSafeInteger(after)||after<0||!Number.isSafeInteger(limit)||limit<1||limit>100)throw new BridgeError('研究游标或页长无效');
    const upper=input.throughId ?? (await one('SELECT COALESCE(MAX(id),0) AS n FROM research_log')).n;
    if(!Number.isSafeInteger(upper)||upper<after)throw new BridgeError('研究批次终点无效');
    const rows=(await q('SELECT * FROM research_log WHERE id>? AND id<=? ORDER BY id LIMIT ?',after,upper,limit+1).all()).results;
    const entries=[];let bytes=1024;
    for(const row of rows.slice(0,limit)) {
      const entry={id:row.id,callId:row.call_id,kind:row.kind,batchId:row.batch_id,createdAt:row.created_at,body:JSON.parse(row.body)};
      const size=new TextEncoder().encode(JSON.stringify(entry)).length;
      if(bytes+size>180*1024)break;entries.push(entry);bytes+=size;
    }
    if(rows.length&&!entries.length)throw new BridgeError('研究单条回执过大',413);
    return {version:1,readAt:time(),entries,nextCursor:entries.at(-1)?.id ?? after,throughId:upper,hasMore:rows.length>entries.length};
  }
  async function batches(input={}) {
    const after=input.afterMinute ?? -1,limit=input.limit ?? 10;
    if(!Number.isSafeInteger(after)||after< -1||!Number.isSafeInteger(limit)||limit<1||limit>30)throw new BridgeError('事件游标无效');
    const upper=input.throughMinute ?? Math.max(after,(await one('SELECT COALESCE(MAX(minute),-1) AS n FROM batches')).n);
    if(!Number.isSafeInteger(upper)||upper<after)throw new BridgeError('事件终点无效');
    const rows=(await q('SELECT * FROM batches WHERE minute>? AND minute<=? ORDER BY minute LIMIT ?',after,upper,limit+1).all()).results;
    const entries=[];let bytes=1024;
    for(const row of rows.slice(0,limit)) {
      const entry={id:row.id,minute:row.minute,createdAt:row.created_at,processedAt:row.processed_at,event:JSON.parse(row.body)};
      const size=new TextEncoder().encode(JSON.stringify(entry)).length;
      if(bytes+size>240*1024)break;entries.push(entry);bytes+=size;
    }
    if(rows.length&&!entries.length)throw new BridgeError('事件单条过大',413);
    return {readAt:time(),entries,nextCursor:entries.at(-1)?.minute ?? after,throughMinute:upper,hasMore:rows.length>entries.length};
  }
  async function evidence(input={}) {
    input={eventIds:[],commandIds:[],noteIds:[],nativeCommandIds:[],...input};
    for(const key of ['eventIds','commandIds','noteIds','nativeCommandIds'])if(!Array.isArray(input[key])||input[key].length>20||input[key].some(id=>typeof id!=='string'||id.length>150))throw new BridgeError('原文身份无效');
    const observations=[],missing=[];let bytes=1024;
    for(const id of input.eventIds) {
      const row=await one('SELECT body FROM observations WHERE id=?',id);
      if(!row){missing.push(id);continue;}
      if(bytes+new TextEncoder().encode(row.body).length>180*1024)break;
      observations.push(JSON.parse(row.body));bytes+=new TextEncoder().encode(row.body).length;
    }
    const read=observations.length+missing.length;
    const commands=[],notes=[],nativeCommands=[];
    for(const id of input.commandIds){const r=await one('SELECT id,session_id,result,created_at FROM commands WHERE id=?',id);if(r)commands.push({commandId:r.id,sessionId:r.session_id,receivedAt:r.created_at,result:JSON.parse(r.result)});else missing.push(`command:${id}`);}
    for(const id of input.noteIds){const r=await one('SELECT id,body,assertion,confidence,basis,created_at,expires_at,supersedes FROM notes WHERE id=?',id);if(r)notes.push({...r,body:JSON.parse(r.body),basis:JSON.parse(r.basis)});else missing.push(`note:${id}`);}
    for(const id of input.nativeCommandIds){
      const r=await one('SELECT command_id,device_id,request_hash,body,permission,grant_revision,state,accepted_at,expires_at,approved_at,attempt_id,claimed_at,result_hash,result,result_at FROM native_requests WHERE command_id=?',id);
      if(r)nativeCommands.push({...r,body:JSON.parse(r.body),result:r.result?JSON.parse(r.result):null});else missing.push(`native:${id}`);
    }
    if(new TextEncoder().encode(JSON.stringify({commands,notes,nativeCommands})).length+bytes>240*1024)throw new BridgeError('原文回执过大，请分别按单条读取',413);
    return {readAt:time(),observations,commands,notes,nativeCommands,missing,remainingEventIds:input.eventIds.slice(read),hasMore:read<input.eventIds.length};
  }
  async function complete(input,actor) {
    const {batchId,resultId,readCallIds,conclusions=[],notification,operation,attention={},supersedes=null}=input;
    if(typeof resultId!=='string'||!resultId.length||resultId.length>100)throw new BridgeError('需要稳定resultId用于重试');
    const resultKey=`result_${resultId}`,requestHash=await sha(canonical(input));
    const previous=await one('SELECT body,actor,created_at FROM research_log WHERE call_id=?',resultKey);
    if(previous) {
      if(previous.actor!==actor||JSON.parse(previous.body).requestHash!==requestHash)throw new BridgeError('resultId不能复用于不同结果',409);
      return {batchId,resultId:resultKey,recorded:true,processedAt:(await one('SELECT processed_at FROM batches WHERE id=?',batchId))?.processed_at ?? null,recordedAt:previous.created_at,replayed:true};
    }
    const batch=await one('SELECT * FROM batches WHERE id=?',batchId);
    if(!batch)throw new BridgeError('找不到事件批次',404);
    if(!Array.isArray(readCallIds)||!readCallIds.length||readCallIds.length>100)throw new BridgeError('需要实际读取回执');
    const calls=[];
    for(const id of [...new Set(readCallIds)]) {
      const row=await one("SELECT body FROM research_log WHERE kind='call_returned' AND actor=? AND json_extract(body,'$.callId')=?",actor,id);
      if(!row)throw new BridgeError('读取回执不存在或不属于当前调用者');
      calls.push(JSON.parse(row.body));
    }
    const data=JSON.parse(batch.body).data;
    // Check contiguous pages against server-recorded parameters, not agent claims.
    let cursor=data.fromChangeId-1;
    const pages=calls.filter(c=>c.tool==='read_changes').sort((a,b)=>a.references.changeIds[0]-b.references.changeIds[0]);
    for(const page of pages) {
      const ids=page.references.changeIds;
      if(page.references.pagination.throughId!==data.throughChangeId||page.arguments.afterId!==cursor||!ids.length)throw new BridgeError('变化分页未连续读完');
      cursor=ids.at(-1);
    }
    if(cursor!==data.throughChangeId||!pages.length||pages.at(-1).references.pagination.hasMore!==false)throw new BridgeError('变化分页未完整读取');
    const expected=(await q('SELECT id FROM changes WHERE id>=? AND id<=? ORDER BY id',data.fromChangeId,data.throughChangeId).all()).results.map(c=>c.id);
    if(canonical(expected)!==canonical(pages.flatMap(p=>p.references.changeIds)))throw new BridgeError('读取内容与批次不一致');
    if(!calls.some(c=>c.tool==='read_current_state'&&c.finishedAt>=batch.created_at&&c.references.pagination.valuesIncluded!==false))throw new BridgeError('需要实际读取本批之后的状态正文');
    if(!notification||!['silent','chat','ordinary_notification'].includes(notification.channel)||!['not_requested','reported_sent','unknown','failed'].includes(notification.result))throw new BridgeError('通知结果无效');
    // This receipt records actions; it never sends a notification or runs a task.
    if(!operation||!['none','task_command'].includes(operation.kind))throw new BridgeError('本阶段不支持此操作类型');
    if(notification.channel==='silent'&&notification.result!=='not_requested')throw new BridgeError('静默不能报告已通知');
    if(operation.kind==='task_command'&&!calls.some(c=>c.tool==='task_command'&&c.references.commandIds.includes(operation.commandId)&&c.references.saved===true))throw new BridgeError('缺少实际计时保存回执');
    if(!Array.isArray(conclusions)||conclusions.length>20)throw new BridgeError('结论数量无效');
    for(const c of conclusions) {
      if(!['bc_native','connector','user_statement','public','habit','inference'].includes(c.sourceClass)||!['high','medium','low','unknown'].includes(c.confidence)||typeof c.summary!=='string'||c.summary.length>1000||typeof c.rationale!=='string'||c.rationale.length>1000||!Array.isArray(c.evidenceCallIds)||!c.evidenceCallIds.length||c.evidenceCallIds.some(id=>!readCallIds.includes(id))||!Array.isArray(c.alternatives)||c.alternatives.length>5||c.alternatives.some(a=>typeof a!=='string'||a.length>500))throw new BridgeError('结论必须有来源、置信度、简短依据、读取证据与替代解释');
    }
    if(supersedes&&!await one("SELECT id FROM research_log WHERE call_id=? AND kind='batch_result' AND batch_id=?",supersedes,batchId))throw new BridgeError('纠正对象不存在或不是同批结果');
    const elapsed=attention.seconds ?? null;
    if(elapsed!==null&&(!Number.isFinite(elapsed)||elapsed<0))throw new BridgeError('注意力时间无效');
    const body={version:1,requestHash,readCallIds,conclusions,notification,operation,attention:{seconds:elapsed,basis:elapsed===null?'unknown':attention.basis==='user_report'?'user_report':'agent_estimate',userFeedback:'unknown'},model:{wake:'observed_tools_called',tokens:null,cost:null},externalCapture:'BC tools only; other connector raw calls unavailable',supersedes};
    if(new TextEncoder().encode(JSON.stringify(body)).length>24000)throw new BridgeError('处理回执过大',413);
    const callId=resultKey,finishedAt=time();
    await db.batch([
      q('INSERT INTO research_log(call_id,kind,batch_id,actor,created_at,body) VALUES(?,?,?,?,?,?)',callId,'batch_result',batchId,actor,finishedAt,JSON.stringify(body)),
      q('UPDATE batches SET processed_at=COALESCE(processed_at,?),processed_by=COALESCE(processed_by,?) WHERE id=?',finishedAt,actor,batchId),
    ]);
    return {batchId,resultId:callId,recorded:true,processedAt:(await one('SELECT processed_at FROM batches WHERE id=?',batchId)).processed_at,recordedAt:finishedAt,notificationEvidence:notification.result==='reported_sent'?'agent_report_not_delivery_receipt':'not_sent_or_unknown',deviceApplication:'unknown',userFeedback:'unknown'};
  }
  return {append,invoke,read,batches,evidence,complete};
}
