import { timingSafeEqual } from "node:crypto";
import { ForwardAllToDots } from "./event-decision.mjs";
import { sourceView, coverageView, stateWarnings, observationSignalValue } from "./state-view.mjs";
import { createObservationHistory } from "./observation-history.mjs";
import { createTaskHistory } from "./task-history.mjs";
import { createPoolRecords } from "./pool-records.mjs";
import { createResearch } from "./research.mjs";
import { createNativeCommands } from "./native-commands.mjs";
import { createTaskApplication } from "./task-application.mjs";
// Durable core: Cloudflare D1 in production, actual SQLite in focused tests.
export class BridgeError extends Error {
  constructor(message,status=400){super(message);this.status=status;}
}
export class CallbackEndpointError extends BridgeError { constructor(message,reason){super(message,502);this.reason=reason;} }
const enc=new TextEncoder();
const changed=r=>Number(r?.meta?.changes ?? r?.changes ?? 0);
// Persisted in the existing retry deadline: longer than two 5s DNS checks and
// the 10s send timeout. A crashed worker leaves a bounded, recoverable lease.
const callbackLeaseMs=60000;
const equal=(a,b)=>typeof a==="string"&&typeof b==="string"&&enc.encode(a).length===enc.encode(b).length&&timingSafeEqual(enc.encode(a),enc.encode(b));
export function canonical(v){
  if(Array.isArray(v))return `[${v.map(canonical).join(",")}]`;
  if(v&&typeof v==="object")return `{${Object.keys(v).sort().map(k=>`${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}
export async function sha(v){return [...new Uint8Array(await crypto.subtle.digest("SHA-256",enc.encode(v)))].map(b=>b.toString(16).padStart(2,"0")).join("");}
function str(v,name,max=200){if(typeof v!=="string"||!v.trim()||v.length>max)throw new BridgeError(`${name} 无效`);return v;}
export function iso(v){if(typeof v!=="string"||!/(Z|[+-]\d\d:\d\d)$/.test(v)||!Number.isFinite(Date.parse(v)))throw new BridgeError("需要带时区的有效时间戳");return new Date(v).toISOString();}
const b64=v=>btoa(String.fromCharCode(...v));
export async function signWebhook(secret,id,time,body){
  if(typeof secret!=="string"||!secret.startsWith("whsec_"))throw new BridgeError("回调密钥无效");
  let bytes;try{bytes=Uint8Array.from(atob(secret.slice(6)),c=>c.charCodeAt(0));}catch{throw new BridgeError("回调密钥无效");}
  if(bytes.length<24||bytes.length>64)throw new BridgeError("回调密钥长度无效");
  const key=await crypto.subtle.importKey("raw",bytes,{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  return `v1,${b64(new Uint8Array(await crypto.subtle.sign("HMAC",key,enc.encode(`${id}.${time}.${body}`))))}`;
}
export async function validateCallback(value,fetcher=(...args)=>globalThis.fetch(...args)){
  let u;try{u=new URL(value);}catch{throw new BridgeError("回调地址无效");}
  const host=u.hostname.toLowerCase();
  if(u.protocol!=="https:"||u.username||u.password||u.hash||(u.port&&u.port!=="443")||!["openai.com","chatgpt.com"].some(d=>host===d||host.endsWith(`.${d}`)))throw new BridgeError("仅接受 OpenAI 或 ChatGPT 的公开 HTTPS 回调");
  let addresses=0;
  for(const type of ["A","AAAA"]){
    const r=await fetcher(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=${type}`,{headers:{Accept:"application/dns-json"},redirect:"manual",signal:AbortSignal.timeout(5000)});
    if(!r.ok)throw new BridgeError("无法验证回调 DNS");const a=await r.json();
    if(a.Status!==0)throw new BridgeError("回调 DNS 无效");
    for(const x of a.Answer??[]){
      if(x.type===1){addresses++;if(/^(0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|22[4-9]\.|2[3-5]\d\.)/.test(x.data))throw new BridgeError("回调不能指向私有地址");}
      if(x.type===28){addresses++;if(/^(::|f[cd]|fe[89ab]|ff)/i.test(x.data))throw new BridgeError("回调不能指向私有地址");}
    }
  }
  if(!addresses)throw new BridgeError("回调没有公开地址");return u.toString();
}
export function createBridge(db,{now=()=>new Date(),fetcher=(...args)=>globalThis.fetch(...args),decisionPolicy=new ForwardAllToDots()}={}){
  const time=()=>now().toISOString(),q=(sql,...args)=>db.prepare(sql).bind(...args);
  const one=(sql,...args)=>q(sql,...args).first(),all=async(sql,...args)=>(await q(sql,...args).all()).results;
  const research=createResearch(db,time);
  const taskApplication=createTaskApplication(db,time);
  const nativeCommands=createNativeCommands(db,time,taskCommand);
  async function registerDevice(v){
    const id=str(v.id,"设备 ID",80),label=str(v.label,"设备名",100);
    if(!Array.isArray(v.scopes)||!v.scopes.length||v.scopes.some(s=>typeof s!=="string"||!/^[a-z][a-z0-9_.-]{1,60}$/.test(s)))throw new BridgeError("来源范围无效");
    if(await one("SELECT id FROM devices WHERE id=?",id))throw new BridgeError("设备 ID 已登记；不自动替换已有凭据",409);
    const token=b64(crypto.getRandomValues(new Uint8Array(32)));
    await q("INSERT INTO devices(id,label,token_hash,scopes,created_at) VALUES(?,?,?,?,?)",id,label,await sha(token),JSON.stringify(v.scopes),time()).run();
    return {id,token,scopes:v.scopes};
  }
  async function authenticateDevice(token){
    if(!token)throw new BridgeError("缺少设备凭据",401);
    const d=await one("SELECT * FROM devices WHERE token_hash=? AND revoked_at IS NULL",await sha(token));
    if(!d)throw new BridgeError("设备凭据无效或已撤销",401);return d;
  }
  async function ingestAuthorized(v,d,scopes){
    if(!Array.isArray(v.observations)||v.observations.length>100)throw new BridgeError("每批最多 100 条观察");
    const accepted=[],ignored=[];
    for(const raw of v.observations){
      const id=str(raw.eventId,"事件 ID",150),source=str(raw.source,"来源",60);
      if(!scopes.includes(source))throw new BridgeError("设备没有此来源权限",403);
      if(raw.schemaVersion!==1||!Number.isSafeInteger(raw.sequence)||raw.sequence<1)throw new BridgeError("观察版本或递增序号无效");
      const observedAt=iso(raw.observedAt),receivedAt=time(),expiresAt=raw.expiresAt==null?null:iso(raw.expiresAt);
      if(Date.parse(observedAt)>now().getTime()+120000||(expiresAt&&Date.parse(expiresAt)<Date.parse(observedAt)))throw new BridgeError("观察时间或有效期无效");
      if(!["observed","user","inferred"].includes(raw.assertion)||raw.value===undefined)throw new BridgeError("需要声明事实或推断，并提供 value");
      const observation={...raw,observedAt,expiresAt,deviceId:d.id,receivedAt},body=JSON.stringify(observation);
      if(enc.encode(body).length>48*1024)throw new BridgeError("观察过大",413);
      const duplicate=await one("SELECT body FROM observations WHERE id=?",id);
      if(duplicate){const old=JSON.parse(duplicate.body);if(canonical({...old,receivedAt:null})!==canonical({...observation,receivedAt:null}))throw new BridgeError("事件 ID 不能复用于不同内容",409);ignored.push(id);continue;}
      const key=`${d.id}:${source}`,prior=await one("SELECT * FROM states WHERE source_key=?",key);
      const hash=await sha(canonical({value:observationSignalValue(source,raw.value),assertion:raw.assertion,confidence:raw.confidence??null}));
      const changed=!prior||prior.value_hash!==hash||(prior.expires_at&&Date.parse(prior.expires_at)<=now().getTime());
      const ops=[q("INSERT OR IGNORE INTO observations(id,source_key,device_id,seq,observed_at,received_at,body) VALUES(?,?,?,?,?,?,?)",id,key,d.id,raw.sequence,observedAt,receivedAt,body),
        q(`INSERT INTO states(source_key,device_id,seq,observed_at,received_at,expires_at,value_hash,body) SELECT ?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM observations WHERE id=? AND body=?)
           ON CONFLICT(source_key) DO UPDATE SET seq=excluded.seq,observed_at=excluded.observed_at,received_at=excluded.received_at,expires_at=excluded.expires_at,value_hash=excluded.value_hash,body=excluded.body
           WHERE excluded.seq>states.seq AND excluded.observed_at>=states.observed_at`,key,d.id,raw.sequence,observedAt,receivedAt,expiresAt,hash,body,id,body)];
      if(changed)ops.push(q(`INSERT OR IGNORE INTO changes(event_id,source_key,occurred_at,body)
         SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM states WHERE source_key=? AND seq=? AND body=?)`,id,key,observedAt,body,key,raw.sequence,body));
      await db.batch(ops);accepted.push(id);
    }
    return {accepted,ignored,receivedAt:time()};
  }
  async function ingest(v,d){return ingestAuthorized(v,d,JSON.parse(d.scopes));}
  async function uploadPool(v,d){
    if(!JSON.parse(d.scopes).includes("user.context"))throw new BridgeError("此设备未登记个人事项权限",403);
    return ingestAuthorized(v,d,["bc.pool","bc.pool.chunk"]);
  }
  const readPoolRecords=createPoolRecords(db,time);
  const sessionView=r=>({id:r.id,title:r.title,status:r.status,startedAt:r.started_at,activeSince:r.active_since,elapsedMs:r.elapsed_ms+(r.status==="running"&&r.active_since?Math.max(0,now().getTime()-Date.parse(r.active_since)):0),updatedAt:r.updated_at,revision:r.revision,lastCommandId:r.last_command_id,provenance:r.provenance,relatedRecordId:r.related_record_id??null,origin:r.origin??null});
  async function taskState(device=null){
    // One SQLite read snapshot: a concurrent finish cannot appear as both active
    // and finished in a device application receipt.
    const rows=await all(`WITH active AS (SELECT * FROM sessions WHERE status!='finished' ORDER BY started_at,id LIMIT 101),
      finished AS (SELECT * FROM sessions WHERE status='finished' ORDER BY updated_at DESC,id DESC LIMIT 101)
      SELECT * FROM active UNION ALL SELECT * FROM finished`);
    const active=rows.filter(r=>r.status!=='finished');
    const state={schemaVersion:1,authority:"bettercalendar",readAt:time(),sessions:active.slice(0,100).map(sessionView),hasMore:active.length>100};
    return device?taskApplication.offer(state,device,rows.filter(r=>r.status==='finished').map(sessionView)):state;
  }
  async function readState(options={}){
    if(options.includeValues!=null&&typeof options.includeValues!=="boolean")throw new BridgeError("includeValues 需要布尔值");
    if(options.sourceKeys!=null&&(!Array.isArray(options.sourceKeys)||options.sourceKeys.length>40||options.sourceKeys.some(k=>typeof k!=="string"||!k.length||k.length>150)))throw new BridgeError("来源筛选需要至多40个sourceKey");
    const readAt=time();
    const sources=(await all("SELECT * FROM states ORDER BY source_key")).map(r=>sourceView(JSON.parse(r.body),r.source_key,readAt));
    let selected=options.sourceKeys==null?sources:sources.filter(s=>options.sourceKeys.includes(s.sourceKey));
    if(options.includeValues===false){
      const metadata=["schemaVersion","eventId","source","deviceId","sequence","assertion","observedAt","receivedAt","expiresAt","sourceKey","freshness","availability","reason","lastObservedAt","lastReceivedAt","lastSuccessfulReadAt","dataRole","usableForCurrentState","observationAgeSeconds","deliveryDelaySeconds","collectionRecency","freshnessMeaning","legacyTimingEntryCursor","legacyTimingEntryMeaning"];
      selected=selected.map(s=>Object.fromEntries(metadata.filter(k=>s[k]!==undefined).map(k=>[k,s[k]])));
    }
    const devices=await all("SELECT id,label,scopes,revoked_at FROM devices ORDER BY id");
    const notes=(await all("SELECT * FROM notes n WHERE (n.expires_at IS NULL OR n.expires_at>?) AND NOT EXISTS(SELECT 1 FROM notes replacement WHERE replacement.supersedes=n.id) ORDER BY created_at DESC LIMIT 30",readAt)).map(n=>options.includeValues===false?{id:n.id,kind:n.kind,assertion:n.assertion,confidence:n.confidence,createdAt:n.created_at,expiresAt:n.expires_at,supersedes:n.supersedes,contentIncluded:false}:{...n,body:JSON.parse(n.body),basis:JSON.parse(n.basis)});
    return {schemaVersion:1,readAt,sources:selected,sourceCount:sources.length,valuesIncluded:options.includeValues!==false,missingSourceKeys:(options.sourceKeys??[]).filter(k=>!sources.some(s=>s.sourceKey===k)),coverage:coverageView(devices,sources),warnings:stateWarnings(sources),
      interpretation:"sources 保留最后一次观察；stale 不是当前活动。coverage 的 not_received 表示此来源尚未上传，不证明用户没有该活动。lastSuccessfulReadAt 为本次可读快照时间，失败时为空，不代表历史从未成功。",
      sessions:(await all("SELECT * FROM sessions WHERE status!='finished' ORDER BY started_at")).map(sessionView),notes};
  }
  async function taskCommand(v,origin="mcp",authorization=null){
    const commandId=str(v.commandId,"commandId",150),requestHash=await sha(canonical(v));
    const replay=await one("SELECT * FROM commands WHERE id=?",commandId);
    if(replay){if(replay.request_hash!==requestHash)throw new BridgeError("commandId 不能复用于不同命令",409);return JSON.parse(replay.result);}
    if(!["start","pause","resume","finish"].includes(v.action)||v.provenance!=="user")throw new BridgeError("计时仅接受用户明确表达；推断请单独保存");
    const occurredAt=v.occurredAt==null?time():iso(v.occurredAt);
    if(Date.parse(occurredAt)>now().getTime()+120000)throw new BridgeError("计时动作不能在未来");
    const guardSQL=authorization?`EXISTS(SELECT 1 FROM native_requests n JOIN native_grants g ON g.device_id=n.device_id JOIN devices d ON d.id=n.device_id WHERE n.command_id=? AND n.request_hash=? AND n.attempt_id=? AND n.device_id=? AND n.permission=? AND n.grant_revision=? AND n.state='dispatching' AND n.approved_at IS NOT NULL AND n.expires_at>? AND g.revision=n.grant_revision AND g.expires_at>? AND d.revoked_at IS NULL AND EXISTS(SELECT 1 FROM json_each(g.body,'$.capabilities') WHERE value=n.permission))`:'1';
    const guardArgs=()=>authorization?[authorization.commandId,authorization.requestHash,authorization.attemptId,authorization.deviceId,authorization.permission,authorization.grantRevision,time(),time()]:[];
    let row,ops;
    if(v.action==="start"){
      const title=str(v.title,"任务名",300),id=`task_${(await sha(commandId)).slice(0,32)}`;
      const relatedRecordId=v.relatedRecordId==null?null:str(v.relatedRecordId,"关联记录 ID",150);
      row={id,title,status:"running",started_at:occurredAt,active_since:occurredAt,elapsed_ms:0,updated_at:occurredAt,revision:1,last_command_id:commandId,provenance:"user",related_record_id:relatedRecordId,origin};
      ops=[q(`INSERT OR IGNORE INTO sessions(id,title,status,started_at,active_since,elapsed_ms,updated_at,revision,last_command_id,provenance,related_record_id,origin) SELECT ?,?,?,?,?,?,?,?,?,?,?,? WHERE ${guardSQL}`,id,title,"running",occurredAt,occurredAt,0,occurredAt,1,commandId,"user",relatedRecordId,origin,...guardArgs())];
    }else{
      const id=str(v.sessionId,"sessionId",80),old=await one("SELECT * FROM sessions WHERE id=?",id);
      if(!old)throw new BridgeError("找不到计时记录",404);
      if(v.expectedRevision!==old.revision)throw new BridgeError("状态已变，请先重新读取",409);
      if(Date.parse(occurredAt)<Date.parse(old.updated_at))throw new BridgeError("动作早于上一状态；请明确修正历史");
      if(old.status==="finished"||(v.action==="pause"&&old.status!=="running")||(v.action==="resume"&&old.status!=="paused"))throw new BridgeError("当前状态不能执行此动作",409);
      row={...old,status:v.action==="resume"?"running":v.action==="pause"?"paused":"finished",active_since:v.action==="resume"?occurredAt:null,elapsed_ms:old.elapsed_ms+(old.active_since?Date.parse(occurredAt)-Date.parse(old.active_since):0),updated_at:occurredAt,revision:old.revision+1,last_command_id:commandId,origin};
      ops=[q(`UPDATE sessions SET status=?,active_since=?,elapsed_ms=?,updated_at=?,revision=?,last_command_id=?,origin=? WHERE id=? AND revision=? AND ${guardSQL}`,row.status,row.active_since,row.elapsed_ms,row.updated_at,row.revision,commandId,origin,id,old.revision,...guardArgs())];
    }
    const result={...sessionView(row),elapsedMs:row.elapsed_ms,commandId,saved:true};
    ops.push(q(`INSERT OR IGNORE INTO commands(id,request_hash,session_id,result,created_at)
       SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM sessions WHERE id=? AND last_command_id=?)`,commandId,requestHash,row.id,JSON.stringify(result),time(),row.id,commandId));
    ops.push(q(`INSERT OR IGNORE INTO changes(event_id,source_key,occurred_at,body)
       SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM commands WHERE id=?)`,`command:${commandId}`,"bc:tasks",occurredAt,JSON.stringify({action:v.action,session:result,assertion:"user",origin}),commandId));
    await db.batch(ops);const committed=await one("SELECT result,request_hash FROM commands WHERE id=?",commandId);
    if(!committed||committed.request_hash!==requestHash)throw new BridgeError("计时并发冲突，请重新读取",409);return JSON.parse(committed.result);
  }
  const {taskHistory,readTaskCommands}=createTaskHistory(db,time,sessionView,taskApplication,readPoolRecords);
  async function acknowledgeBatch(id,ownerId) {
    str(id,"批次 ID",100);if(!await one("SELECT id FROM batches WHERE id=?",id))throw new BridgeError("找不到批次",404);
    await q("UPDATE batches SET processed_at=COALESCE(processed_at,?),processed_by=COALESCE(processed_by,?) WHERE id=?",time(),ownerId,id).run();
    return {batchId:id,processedAt:(await one("SELECT processed_at FROM batches WHERE id=?",id)).processed_at};
  }
  async function recordNote(v){
    const id=str(v.id,"记录 ID",150),kind=str(v.kind,"记录类别",60);
    if(!["user","inferred"].includes(v.assertion)||!["high","medium","low","unknown"].includes(v.confidence)||!Array.isArray(v.basis)||(v.assertion==="inferred"&&!v.basis.length))throw new BridgeError("需要事实或推断标记、把握程度和依据");
    const body=JSON.stringify(v.body);if(!body||enc.encode(body).length>16384)throw new BridgeError("记录内容无效");
    const old=await one("SELECT * FROM notes WHERE id=?",id);
    if(old&&(old.body!==body||old.assertion!==v.assertion||old.kind!==kind))throw new BridgeError("记录 ID 冲突",409);
    await q("INSERT OR IGNORE INTO notes(id,kind,body,assertion,confidence,basis,created_at,expires_at,supersedes) VALUES(?,?,?,?,?,?,?,?,?)",id,kind,body,v.assertion,v.confidence,JSON.stringify(v.basis),time(),v.expiresAt==null?null:iso(v.expiresAt),v.supersedes??null).run();
    return {id,saved:true,assertion:v.assertion};
  }
  async function readChanges(afterId=0,limit=100,throughId=null){
    if(!Number.isSafeInteger(afterId)||afterId<0)throw new BridgeError("游标无效");
    if(!Number.isSafeInteger(limit)||limit<1||limit>100)throw new BridgeError("每页需要1至100条变化");
    if(throughId!=null&&(!Number.isSafeInteger(throughId)||throughId<0))throw new BridgeError("批次终点无效");
    const rows=throughId==null?await all("SELECT * FROM changes WHERE id>? ORDER BY id LIMIT ?",afterId,limit+1):await all("SELECT * FROM changes WHERE id>? AND id<=? ORDER BY id LIMIT ?",afterId,throughId,limit+1);
    const changes=[];let bytes=1024;
    for(const r of rows.slice(0,limit)){
      const entry={id:r.id,sourceKey:r.source_key,occurredAt:r.occurred_at,observation:JSON.parse(r.body)},size=enc.encode(JSON.stringify(entry)).length;
      if(bytes+size>128*1024){if(!changes.length)throw new BridgeError("单条变化过大，原记录已保留，请检查格式",413);break;}
      changes.push(entry);bytes+=size;
    }
    return {changes,nextCursor:changes.at(-1)?.id??afterId,hasMore:rows.length>changes.length,throughId};
  }
  async function sendSigned(s,id,body){
    await validateCallback(s.callback,fetcher);const timestamp=Math.floor(now().getTime()/1000).toString();
    // Workers supports manual/follow; manual returns redirects without following.
    const response=await fetcher(s.callback,{method:"POST",redirect:"manual",signal:AbortSignal.timeout(10000),headers:{"Content-Type":"application/json","webhook-id":id,"webhook-timestamp":timestamp,"webhook-signature":await signWebhook(s.secret,id,timestamp,body),"X-MCP-Subscription-Id":s.id},body});
    if(response.status>=300&&response.status<400)throw new CallbackEndpointError("回调不能跳转","invalid_url");
    return response;
  }
  async function subscribe(v,ownerId){
    if(v.name!=="state.minute_changed"||v.delivery?.mode!=="webhook"||Object.keys(v.arguments??{}).length)throw new BridgeError("不支持的订阅");
    if(v.ttlMs!=null&&(!Number.isFinite(v.ttlMs)||v.ttlMs<1))throw new BridgeError("订阅有效期无效");
    await signWebhook(v.delivery.secret,"validate","0","");
    let callback;try{callback=await validateCallback(v.delivery.url,fetcher);}catch(error){
      let hostname;try{hostname=new URL(v.delivery.url).hostname;}catch{}
      // A public hostname and our own fixed validation label locate integration
      // failures without exposing the callback path, secret or request body.
      const known=["回调地址无效","仅接受 OpenAI 或 ChatGPT 的公开 HTTPS 回调","无法验证回调 DNS","回调 DNS 无效","回调不能指向私有地址","回调没有公开地址"];
      console.warn("state-bridge-callback-rejected",{hostname,validation:known.includes(error?.message)?error.message:"DNS请求失败",failureType:error?.name,...(!known.includes(error?.message)?{dnsFailure:String(error?.message??"unknown").slice(0,200)}:{})});
      throw new CallbackEndpointError("回调地址验证失败","invalid_url");
    }
    const id=`sub_${(await sha(canonical({ownerId,callback,name:v.name,arguments:{}}))).slice(0,32)}`;
    const prior=await one("SELECT * FROM subscriptions WHERE id=?",id);
    let verifiedAt=prior?.verified_at;
    if(!prior||!equal(prior.secret,v.delivery.secret)||!verifiedAt||Date.parse(verifiedAt)<now().getTime()-300000){
      const challenge=b64(crypto.getRandomValues(new Uint8Array(32)));
      let r;
      try{r=await sendSigned({id,callback,secret:v.delivery.secret},`verify_${crypto.randomUUID()}`,JSON.stringify({type:"verification",challenge}));}
      catch(error){if(error instanceof CallbackEndpointError)throw error;throw new CallbackEndpointError("回调验证连接失败",error?.name==="TimeoutError"?"timeout":"network_error");}
      let echoed;try{const body=await r.text();if(body.length>32000)throw new Error();echoed=JSON.parse(body).challenge;}catch{throw new CallbackEndpointError("回调挑战没有有效响应","challenge_failed");}
      if(!r.ok||!equal(echoed,challenge))throw new CallbackEndpointError("回调挑战验证失败","challenge_failed");
      verifiedAt=time();
    }
    const expiry=new Date(now().getTime()+Math.min(7*86400000,v.ttlMs??7*86400000)).toISOString();
    await q("INSERT INTO subscriptions(id,owner_id,callback,secret,expires_at,created_at,verified_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET secret=excluded.secret,expires_at=excluded.expires_at,verified_at=excluded.verified_at",id,ownerId,callback,v.delivery.secret,expiry,time(),verifiedAt).run();
    return {id,refreshBefore:expiry,cursor:null,truncated:false};
  }
  async function unsubscribe(v,ownerId){if(v.name!=="state.minute_changed"||typeof v.delivery?.url!=="string")throw new BridgeError("订阅参数无效");await q("DELETE FROM subscriptions WHERE owner_id=? AND callback=?",ownerId,v.delivery.url).run();return {};}
  async function flush(){
    const t=time(),minute=Math.floor(now().getTime()/60000);
    for(const s of await all("SELECT * FROM states WHERE expires_at IS NOT NULL AND expires_at<=?",t))await q("INSERT OR IGNORE INTO changes(event_id,source_key,occurred_at,body) VALUES(?,?,?,?)",`stale:${s.source_key}:${s.seq}`,s.source_key,s.expires_at,JSON.stringify({sourceKey:s.source_key,freshness:"stale",assertion:"observed",value:null})).run();
    let batch=await one("SELECT * FROM batches WHERE minute=?",minute),decision=null;
    const last=await one("SELECT through_id FROM batches ORDER BY minute DESC LIMIT 1"),pending=await all("SELECT * FROM changes WHERE id>? ORDER BY id LIMIT 1000",last?.through_id??0);
    if(!batch&&pending.length){
      const id=`minute_${minute}`,data={schemaVersion:1,readLatestState:true,fromChangeId:pending[0].id,throughChangeId:pending.at(-1).id,changes:pending.map(r=>({id:r.id,sourceKey:r.source_key,occurredAt:r.occurred_at,observation:JSON.parse(r.body)})),omittedCount:0};
      decision=await decisionPolicy.decide({readAt:t,changes:data.changes});
      if(typeof decision?.forward!=="boolean"||typeof decision.policy!=="string")throw new BridgeError("判断接口没有返回有效决定",503);
      // Deferring never advances the durable cursor or discards observations.
      if(decision.forward){
        data.decision=decision;
        while(enc.encode(JSON.stringify(data)).length>180*1024&&data.changes.length)data.changes.pop();data.omittedCount=pending.length-data.changes.length;
        await q("INSERT OR IGNORE INTO batches(id,minute,through_id,created_at,body) VALUES(?,?,?,?,?)",id,minute,pending.at(-1).id,t,JSON.stringify({eventId:id,name:"state.minute_changed",timestamp:t,data,cursor:null})).run();batch=await one("SELECT * FROM batches WHERE minute=?",minute);
      }
    }
    const subs=await all("SELECT * FROM subscriptions WHERE expires_at IS NULL OR expires_at>?",t);
    if(batch)for(const s of subs)await q("INSERT OR IGNORE INTO deliveries(id,subscription_id,batch_id,status,next_attempt_at) VALUES(?,?,?,?,?)",`${s.id}:${batch.id}`,s.id,batch.id,"pending",t).run();
    await q("UPDATE deliveries SET status='failed',last_error='重试次数已用尽；接收结果可能未知' WHERE status='pending' AND attempts>=8 AND next_attempt_at<=?",t).run();
    const work=await all("SELECT d.*,s.callback,s.secret,b.body FROM deliveries d JOIN subscriptions s ON s.id=d.subscription_id JOIN batches b ON b.id=d.batch_id WHERE d.status='pending' AND d.next_attempt_at<=? AND (s.expires_at IS NULL OR s.expires_at>?) ORDER BY b.minute LIMIT 8",t,t);
    let delivered=0;
    for(const d of work){
      const at=time(),attempts=d.attempts+1,leaseUntil=new Date(Date.parse(at)+callbackLeaseMs).toISOString();
      // Reading a pending row does not own it. Conditional acquisition works
      // across processes/isolate restarts; no process-local mutex or new table.
      const acquired=await q("UPDATE deliveries SET attempts=?,next_attempt_at=? WHERE id=? AND status='pending' AND attempts=? AND attempts<8 AND next_attempt_at=? AND next_attempt_at<=? AND EXISTS(SELECT 1 FROM subscriptions WHERE id=deliveries.subscription_id AND (expires_at IS NULL OR expires_at>?))",attempts,leaseUntil,d.id,d.attempts,d.next_attempt_at,at,at).run();
      if(!changed(acquired))continue;
      await research.append('callback_attempt_started',d.batch_id,{deliveryId:d.id,subscriptionId:d.subscription_id,attempt:attempts,leaseUntil,channel:'state.minute_changed',receiverProcessing:'unknown'});
      // Recording or subscription checks may outlive the lease. Never start a
      // network send after losing ownership or after subscription withdrawal.
      if(!await one("SELECT d.id FROM deliveries d JOIN subscriptions s ON s.id=d.subscription_id WHERE d.id=? AND d.status='pending' AND d.attempts=? AND d.next_attempt_at=? AND d.next_attempt_at>? AND (s.expires_at IS NULL OR s.expires_at>?)",d.id,attempts,leaseUntil,time(),time())){
        await research.append('callback_attempt_finished',d.batch_id,{deliveryId:d.id,subscriptionId:d.subscription_id,attempt:attempts,receiverAccepted:null,httpStatus:null,outcome:'not_started',receiverProcessing:'unknown'});continue;
      }
      let ok=false,terminal=false,error="",httpStatus=null;
      try{const r=await sendSigned({id:d.subscription_id,callback:d.callback,secret:d.secret},d.batch_id,d.body);httpStatus=r.status;ok=r.ok;terminal=[410,413].includes(r.status);error=`HTTP ${r.status}`;}catch{error="回调连接或验证失败";}
      const status=ok?"received":terminal||attempts>=8?"failed":"pending";
      const saved=await q("UPDATE deliveries SET status=?,next_attempt_at=?,received_at=?,last_error=? WHERE id=? AND status='pending' AND attempts=? AND next_attempt_at=?",status,new Date(now().getTime()+Math.min(3600000,30000*2**attempts)).toISOString(),ok?time():null,ok?null:error,d.id,attempts,leaseUntil).run();
      await research.append('callback_attempt_finished',d.batch_id,{deliveryId:d.id,subscriptionId:d.subscription_id,attempt:attempts,receiverAccepted:httpStatus===null?null:ok,httpStatus,outcome:changed(saved)?status:'superseded',receiverProcessing:'unknown'});
      if(ok&&changed(saved))delivered++;
    }
    return {minute,batchId:batch?.id??null,delivered,activeSubscriptions:subs.length,deferred:decision?.forward===false,decision:batch?JSON.parse(batch.body).data.decision??null:decision,processing:"回调收到不代表 Dot 已分析"};
  }
  async function diagnostics(){return {readAt:time(),devices:await all("SELECT id,label,scopes,created_at,revoked_at FROM devices"),sourceCount:(await one("SELECT COUNT(*) AS n FROM states")).n,subscriptions:await all("SELECT id,expires_at,created_at FROM subscriptions"),deliveries:await all("SELECT batch_id,status,attempts,received_at,last_error FROM deliveries ORDER BY next_attempt_at DESC LIMIT 15"),batches:await all("SELECT id,created_at,processed_at FROM batches ORDER BY minute DESC LIMIT 15")};}
  const recordContext=(input,actor)=>input.kind==='bc.research.batch_result'
    ? research.complete({...input.body,resultId:input.body?.resultId ?? input.id},actor)
    : recordNote(input);
  return {research,taskApplication,nativeCommands,recordContext,registerDevice,authenticateDevice,ingest,uploadPool,readPoolRecords,readState,readObservationHistory:createObservationHistory(db,time),taskState,taskCommand,taskHistory,readTaskCommands,acknowledgeBatch,recordNote,readChanges,subscribe,unsubscribe,flush,diagnostics,
    revokeDevice:async id=>{await q("UPDATE devices SET revoked_at=? WHERE id=?",time(),id).run();return {revoked:true};}};
}
