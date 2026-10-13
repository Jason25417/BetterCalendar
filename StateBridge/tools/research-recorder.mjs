#!/usr/bin/env node
// Personal local recorder. No MCP notification, command or write client exists.
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, readFileSync, writeFileSync, chmodSync, renameSync, statSync, readdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { shadowDecision,SHADOW_VERSION } from '../server/lib/shadow-decision.mjs';

export const ORIGIN='https://jason-state-bridge.jason25417.chatgpt.site';
export const defaults={version:1,maxBytes:2*1024**3,retentionDays:365,debugFeedback:false,pollSeconds:60};
const encode=v=>JSON.stringify(v),hash=v=>createHash('sha256').update(v).digest('hex');
const secretKey=/token|secret|password|authorization|credential|api.?key|cookie/i;
export function redact(value,secrets=[]) {
  if(typeof value==='string') {
    let clean=value.replace(/\b(?:Bearer\s+\S+|whsec_[\w+/=-]+|sk-[\w-]{12,})/gi,'[redacted]');
    for(const s of secrets.filter(s=>typeof s==='string'&&s.length>7))clean=clean.split(s).join('[redacted]');
    return clean;
  }
  if(Array.isArray(value))return value.map(v=>redact(v,secrets));
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,secretKey.test(k)?'[redacted]':redact(v,secrets)]));
  return value;
}
export function sourceClass(source,assertion) {
  if(assertion==='user')return 'user_statement';
  if(assertion==='inferred')return 'inference';
  return source?.startsWith('bc.')||source==='bc:tasks'?'bc_native':'connector';
}
export function comparisonInputs(changes,window,{question='是否需要提醒或执行？',context=[]}={}) {
  const tagged=changes.map(c=>({...c,sourceClass:sourceClass(c.observation?.source ?? c.sourceKey,c.observation?.assertion)}));
  return ['bc_only','bc_connectors','personalized'].map(group=>({group,question,window,context:group==='personalized'?context:[],changes:tagged.filter(c=>group==='personalized'||group==='bc_connectors'&&!['habit','inference'].includes(c.sourceClass)||group==='bc_only'&&['bc_native','user_statement'].includes(c.sourceClass)),coverageDifference:group==='bc_only'?'excludes connectors, habits and inference':group==='bc_connectors'?'excludes habits and inference; no extra connector calls during replay':context.length?'includes archived personalization with original assertion and basis':'no archived habit/preference context; cannot claim its benefit',reasoning:'input comparison, not proof of model quality'}));
}
function atomic(path,value) {
  writeFileSync(path+'.new',encode(value),{mode:0o600});renameSync(path+'.new',path);chmodSync(path,0o600);
}
export class Recorder {
  constructor(root,{config={},clock=()=>new Date(),secrets=[]}={}) {
    this.root=resolve(root);this.clock=clock;this.secrets=secrets;
    mkdirSync(this.root,{recursive:true,mode:0o700});chmodSync(this.root,0o700);
    const configPath=join(this.root,'config.json');
    this.config={...defaults,...(existsSync(configPath)?JSON.parse(readFileSync(configPath,'utf8')):{}),...config};
    if(this.config.version!==1||!Number.isSafeInteger(this.config.maxBytes)||this.config.maxBytes<10000||!Number.isFinite(this.config.retentionDays)||this.config.retentionDays<1||!Number.isFinite(this.config.pollSeconds)||this.config.pollSeconds<10)throw Error('invalid recorder configuration');
    atomic(configPath,this.config);
    this.db=new DatabaseSync(join(this.root,'research.sqlite'));chmodSync(join(this.root,'research.sqlite'),0o600);
    this.db.exec('PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS snapshots(hash TEXT PRIMARY KEY, body TEXT NOT NULL, created_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS calls(id INTEGER PRIMARY KEY, body TEXT NOT NULL); CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, body TEXT NOT NULL); CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS failures(id INTEGER PRIMARY KEY, occurred_at TEXT NOT NULL, category TEXT NOT NULL);');
  }
  get(key,fallback=null){const row=this.db.prepare('SELECT value FROM meta WHERE key=?').get(key);return row?JSON.parse(row.value):fallback;}
  set(key,value){this.db.prepare('INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key,encode(value));}
  usage(){return readdirSync(this.root).reduce((n,f)=>n+statSync(join(this.root,f)).size,0);}
  snapshot(value) {
    const body=encode(redact(value,this.secrets)),id=hash(body);
    if(!this.db.prepare('SELECT hash FROM snapshots WHERE hash=?').get(id)) {
      if(this.usage()+Buffer.byteLength(body)>this.config.maxBytes)throw Error('capacity_exceeded: collection stopped; cursor retained');
      this.db.prepare('INSERT INTO snapshots VALUES(?,?,?)').run(id,body,this.clock().toISOString());
    }
    return id;
  }
  async call(client,path,args) {
    if(!['research/batches','research/changes','research/log','research/state','research/evidence'].includes(path))throw Error('read-only recorder rejects side effects');
    const startedAt=this.clock().toISOString();
    const requestSnapshot=this.snapshot({version:1,kind:'call_started',tool:path,arguments:args,startedAt});
    let response;
    try { response=await client(path,args); }
    catch(e) { this.db.prepare('INSERT INTO failures(occurred_at,category) VALUES(?,?)').run(this.clock().toISOString(),e.status?`HTTP_${e.status}`:'network_or_read_error');this.snapshot({version:1,kind:'call_failed',requestSnapshot,tool:path,arguments:args,startedAt,finishedAt:this.clock().toISOString(),status:e.status ?? null});throw e; }
    const snapshot=this.snapshot({version:1,tool:path,arguments:args,requestSnapshot,startedAt,returnedAt:this.clock().toISOString(),response});
    return {response,snapshot};
  }
  async tick(client) {
    if(existsSync(join(this.root,'STOP')))return {stopped:true};
    // New collection begins now. Do not invent traces for older processed events.
    const start=this.get('startMinute',Math.floor(this.clock().getTime()/60000)-1);
    this.set('startMinute',start);
    let cursor=this.get('minuteCursor',start),upper;
    while(true) {
      const {response:page,snapshot:pageSnapshot}=await this.call(client,'research/batches',{afterMinute:cursor,limit:10,...(upper==null?{}:{throughMinute:upper})});upper=page.throughMinute;
      for(const batch of page.entries) {
        const data=batch.event.data;let after=data.fromChangeId-1,changes=[],snapshots=[pageSnapshot];
        while(true) {
          const result=await this.call(client,'research/changes',{afterId:after,limit:100,throughId:data.throughChangeId});snapshots.push(result.snapshot);changes.push(...result.response.changes);
          if(result.response.nextCursor<=after&&result.response.hasMore)throw Error('non_advancing_page');
          after=result.response.nextCursor;if(!result.response.hasMore)break;
        }
        if(after!==data.throughChangeId)throw Error('incomplete_batch');
        const state=await this.call(client,'research/state',{});snapshots.push(state.snapshot);
        const prior=this.get('shadowBaseline',{}),shadow=shadowDecision(changes,prior);
        const receipt={version:1,id:batch.id,collectedAt:this.clock().toISOString(),batch,changes,snapshots,stateSnapshot:state.snapshot,coverage:state.response.coverage,
          gates:{receive:'durable_batch_and_complete_pages',wake:{baseline:data.decision ?? {policy:'ForwardAllToDots'},actual:'callback_receipt_is_not_proof_of_model_wake'},notify:{actual:'unknown_until_agent_receipt'},execute:{actual:'unknown_until_command_receipt',permission:'explicit_user_request_only'}},
          shadow:{...shadow,next:undefined},shadowPrior:prior,window:{from:batch.createdAt,throughChangeId:data.throughChangeId,readAt:state.response.readAt},
          gaps:['External connector raw tool calls not captured','Agent tool response bodies referenced, not exact local HTTP snapshots','Model tokens and cost unknown','Device application unknown without separate receipt','No user feedback is unknown, not approval'],attention:{seconds:null,userFeedback:'unknown'},debugFeedback:this.config.debugFeedback};
        const body=encode(redact(receipt,this.secrets));
        if(this.usage()+Buffer.byteLength(body)>this.config.maxBytes)throw Error('capacity_exceeded');
        this.db.exec('BEGIN IMMEDIATE');
        try {
          this.db.prepare('INSERT INTO runs VALUES(?,?) ON CONFLICT(id) DO NOTHING').run(batch.id,body);
          this.set('shadowBaseline',shadow.next);this.set('minuteCursor',batch.minute);this.db.exec('COMMIT');
        }catch(e){this.db.exec('ROLLBACK');throw e;}
      }
      cursor=page.nextCursor;if(!page.hasMore)break;
    }
    let after=this.get('logCursor',0),through;
    while(true) {
      const {response:page,snapshot:logPageSnapshot}=await this.call(client,'research/log',{afterId:after,limit:30,...(through==null?{}:{throughId:through})});through=page.throughId;
      for(const entry of page.entries) {
        const localEvidence=[];
        const ids=entry.body.references?.observationIds ?? [];
        for(let start=0;start<ids.length;start+=20) {
          let remaining=ids.slice(start,start+20);
          while(remaining.length) {
            const {response:evidence,snapshot}=await this.call(client,'research/evidence',{eventIds:remaining});localEvidence.push(snapshot);
            if(evidence.remainingEventIds.length===remaining.length)throw Error('non_advancing_evidence');
            remaining=evidence.remainingEventIds;
          }
        }
        for(const key of ['commandIds','noteIds'])for(const id of entry.body.references?.[key] ?? []){const {snapshot}=await this.call(client,'research/evidence',{[key]:[id]});localEvidence.push(snapshot);}
        const body=encode(redact({...entry,localEvidence,logPageSnapshot},this.secrets));
        if(this.usage()+Buffer.byteLength(body)>this.config.maxBytes)throw Error('capacity_exceeded');
        this.db.exec('BEGIN IMMEDIATE');try{this.db.prepare('INSERT OR IGNORE INTO calls VALUES(?,?)').run(entry.id,body);this.set('logCursor',entry.id);this.db.exec('COMMIT');}catch(e){this.db.exec('ROLLBACK');throw e;}
      }
      after=page.nextCursor;if(!page.hasMore)break;
    }
    return {runs:this.db.prepare('SELECT COUNT(*) n FROM runs').get().n,calls:this.db.prepare('SELECT COUNT(*) n FROM calls').get().n,bytes:this.usage(),minuteCursor:this.get('minuteCursor'),logCursor:this.get('logCursor'),stopped:false};
  }
  replay(id) {
    const row=this.db.prepare('SELECT body FROM runs WHERE id=?').get(id);if(!row)throw Error('unknown run');
    const run=JSON.parse(row.body),state=this.db.prepare('SELECT body FROM snapshots WHERE hash=?').get(run.stateSnapshot);
    const context=(state?JSON.parse(state.body).response?.notes ?? []:[]).filter(n=>['habit','preference','personalization'].includes(n.kind)).map(n=>({...n,sourceClass:'habit',layer:'personalization',assertion:n.assertion}));
    const inputs=comparisonInputs(run.changes,run.window,{context});
    return {version:1,id,sideEffects:false,network:false,recordedShadow:run.shadow,replayShadowVersion:SHADOW_VERSION,policyChanged:run.shadow.version!==SHADOW_VERSION,groups:inputs.map(i=>({...i,shadow:shadowDecision(i.changes,run.shadowPrior ?? {})})),evaluation:{falsePositives:null,falseNegatives:null,usefulness:null,cost:null,reason:'requires labeled real samples; silence is not approval'}};
  }
  stats() {
    const calls=this.db.prepare('SELECT body FROM calls ORDER BY id').all().map(r=>JSON.parse(r.body));
    const runs=this.db.prepare('SELECT body FROM runs').all().map(r=>JSON.parse(r.body));
    const byBatch=new Map(),firstByBatch=new Map();
    for(const call of calls)if(call.kind==='batch_result'){byBatch.set(call.batchId,call);if(!firstByBatch.has(call.batchId))firstByBatch.set(call.batchId,call);}
    const summary={version:1,generatedAt:this.clock().toISOString(),archivedBatches:runs.length,
      recordedAgentResults:0,awaitingResearchResult:0,processedWithoutAction:0,
      shadowWouldSkipWake:0,processedWithoutActionAndShadowWouldSkip:0,
      notificationReportedSent:0,notificationFailed:0,operationReceipts:0,
      correctionCount:calls.filter(c=>c.kind==='batch_result'&&c.body.supersedes).length,
      shadowPolicyVersions:Object.fromEntries([...new Set(runs.map(r=>r.shadow.version))].map(v=>[v,runs.filter(r=>r.shadow.version===v).length])),
      errors:{localReadFailures:this.db.prepare('SELECT COUNT(*) n FROM failures').get().n,archivedCallFailures:calls.filter(c=>c.kind==='call_failed').length},
      modelTokens:null,modelCost:null,attentionSeconds:null,usefulness:null,userApproval:'unknown',
      caveats:['Shadow does not change ForwardAll or prove saved calls/cost',
        'Reported notification is not device delivery or proof the user saw it',
        'Missing result is not proof the model was not woken',
        'Corrected results counted once per batch; old evidence retained',
        'User silence is unknown, not approval',
        'Delay measures server batch creation to saved result, not source occurrence or user delivery'],batches:[]};
    for(const run of runs) {
      const result=byBatch.get(run.id),skip=run.shadow.wake===false;
      const noAction=!!result&&result.body.notification.channel==='silent'&&result.body.notification.result==='not_requested'&&result.body.operation.kind==='none';
      if(result)summary.recordedAgentResults++;else summary.awaitingResearchResult++;
      if(noAction)summary.processedWithoutAction++;
      if(skip)summary.shadowWouldSkipWake++;
      if(noAction&&skip)summary.processedWithoutActionAndShadowWouldSkip++;
      if(result?.body.notification.result==='reported_sent')summary.notificationReportedSent++;
      if(result?.body.notification.result==='failed')summary.notificationFailed++;
      if(result?.body.operation.kind==='task_command')summary.operationReceipts++;
      const delay=receipt=>{const ms=Date.parse(receipt?.createdAt)-Date.parse(run.batch.createdAt);return Number.isFinite(ms)&&ms>=0?ms/1000:null;};
      summary.batches.push({id:run.id,firstResultDelaySeconds:delay(firstByBatch.get(run.id)),latestResultDelaySeconds:delay(result),resultId:result?.callId??null,recordedAt:result?.createdAt??null,
        agentResult:result?'recorded':'unknown',processedWithoutAction:noAction,shadowWouldSkipWake:skip,
        notification:result?.body.notification??null,operation:result?.body.operation??null});
    }
    return summary;
  }
  view() {
    const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const calls=this.db.prepare('SELECT body FROM calls ORDER BY id').all().map(r=>JSON.parse(r.body));
    const runs=this.db.prepare('SELECT body FROM runs').all().map(r=>JSON.parse(r.body));
    const summary=this.stats();
    const rows=runs.reverse().map(run=>{
      const results=calls.filter(c=>c.batchId===run.id&&c.kind==='batch_result');
      return `<article><h2>${escape(run.id)}</h2><p>接收：完整读取 ${run.changes.length} 条变化 · 读取时间：${escape(run.collectedAt)}</p><p>ForwardAll：保留原路径 · Shadow：${run.shadow.wake?'建议唤醒':'也许可省掉唤醒'}（没有改变真实路径）</p><p>结果：${results.length?'有代理处理回执':'尚无完整研究回执；不推断已处理或未处理'} · 用户认可：未知</p><details><summary>来源、时效和缺口</summary><pre>${escape(JSON.stringify({coverage:run.coverage,gaps:run.gaps},null,2))}</pre></details><details><summary>判断与通知／操作结果</summary><pre>${escape(JSON.stringify(results,null,2))}</pre></details><details><summary>完整事件和本地原文索引</summary><pre>${escape(JSON.stringify(run,null,2))}</pre></details>${this.config.debugFeedback?'<p>调试反馈已启用：静默处理只显示在这里，不发送手机通知；查看成本尚未计时。</p>':''}</article>`;
    }).join('');
    const file=join(this.root,'review.html');
    writeFileSync(file,`<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>BC 研究记录</title><style>body{font:16px system-ui;max-width:900px;margin:32px auto;padding:0 20px;background:#faf8f5;color:#292724}article{border-top:1px solid #ccc;padding:16px 0}h2{font-size:18px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}summary{padding:8px;cursor:pointer}</style><h1>BC 研究记录</h1><p>检查助手的行为，不评判你的生活。原文保存在本地 SQLite；此页面无网络、无操作按钮。</p><p>${runs.length} 个事件样本 · ${calls.length} 条调用／结果回执。缺失日志不追认；未反馈不代表同意。</p><p>代理已保存结果 ${summary.recordedAgentResults} 批 · 其中无提醒／操作 ${summary.processedWithoutAction} 批 · 尚无研究结果 ${summary.awaitingResearchResult} 批。</p><p>Shadow 建议未来可省唤醒 ${summary.shadowWouldSkipWake} 批（真实 ForwardAll 仍运行，不表示已节省调用）；通知仅有代理报告，送达与看到另验。模型费用、注意力成本和有用程度均未知。</p><details><summary>实验汇总与错误</summary><pre>${escape(JSON.stringify(summary,null,2))}</pre></details>${rows||'<p>尚无本轮采集样本。</p>'}</html>`,{mode:0o600});chmodSync(file,0o600);return file;
  }
  export(path) {
    const data={version:1,exportedAt:this.clock().toISOString(),config:this.config,summary:this.stats(),runs:this.db.prepare('SELECT body FROM runs').all().map(r=>JSON.parse(r.body)),calls:this.db.prepare('SELECT body FROM calls').all().map(r=>JSON.parse(r.body)),snapshots:this.db.prepare('SELECT * FROM snapshots').all().map(r=>({...r,body:JSON.parse(r.body)})),failures:this.db.prepare('SELECT * FROM failures').all()};
    const file=resolve(path);if(existsSync(file))throw Error('export destination exists');writeFileSync(file,encode(data),{mode:0o600});return {file,bytes:statSync(file).size};
  }
  prune() {
    const cutoff=new Date(this.clock().getTime()-this.config.retentionDays*86400000).toISOString();
    // Explicit command only. Preserve snapshots referenced by retained traces.
    const live=new Set();for(const r of this.db.prepare('SELECT body FROM runs').all()){const run=JSON.parse(r.body);if(run.collectedAt>=cutoff)for(const id of run.snapshots)live.add(id);}
    for(const row of this.db.prepare('SELECT body FROM calls').all()){const c=JSON.parse(row.body);if(c.createdAt>=cutoff)for(const id of [c.logPageSnapshot,...(c.localEvidence ?? [])])if(id)live.add(id);}
    const snapshots=this.db.prepare('SELECT hash,body,created_at FROM snapshots').all();
    for(const s of snapshots)if(s.created_at>=cutoff)live.add(s.hash);
    for(let changed=true;changed;){changed=false;for(const s of snapshots)if(live.has(s.hash)){const parent=JSON.parse(s.body).requestSnapshot;if(parent&&!live.has(parent)){live.add(parent);changed=true;}}}
    this.db.exec('BEGIN');try{for(const r of this.db.prepare('SELECT id,body FROM runs').all())if(JSON.parse(r.body).collectedAt<cutoff)this.db.prepare('DELETE FROM runs WHERE id=?').run(r.id);
      for(const row of this.db.prepare('SELECT id,body FROM calls').all())if(JSON.parse(row.body).createdAt<cutoff)this.db.prepare('DELETE FROM calls WHERE id=?').run(row.id);
      for(const s of this.db.prepare('SELECT hash,created_at FROM snapshots').all())if(s.created_at<cutoff&&!live.has(s.hash))this.db.prepare('DELETE FROM snapshots WHERE hash=?').run(s.hash);
      this.db.prepare('DELETE FROM failures WHERE occurred_at<?').run(cutoff);
      this.db.exec('COMMIT');}catch(e){this.db.exec('ROLLBACK');throw e;}
    this.db.exec('VACUUM');
    return {retentionDays:this.config.retentionDays,cutoff,conservative:true};
  }
}
function credentials() {
  const p=spawnSync('security',['find-generic-password','-s','com.jason.BetterCalendar.StateBridge','-a','dot-state-bridge-v1','-w'],{encoding:'utf8',timeout:8000});
  if(p.status!==0)throw Error('existing_keychain_credentials_unavailable');
  const c=JSON.parse(p.stdout);if(c.siteURL.replace(/\/$/,'')!==ORIGIN)throw Error('unapproved_origin');return c;
}
function clientFor(c) {
  return async(path,args)=>{
    const r=await fetch(`${ORIGIN}/api/${path}`,{method:'POST',redirect:'manual',signal:AbortSignal.timeout(20000),headers:{'Content-Type':'application/json','OAI-Sites-Authorization':`Bearer ${c.platformToken}`,Authorization:`Bearer ${c.deviceToken}`},body:encode(args)});
    if(!r.ok){const error=Error('read_failed');error.status=r.status;throw error;}return r.json();
  };
}
async function main() {
  const [mode='once',...args]=process.argv.slice(2),root=join(homedir(),'Library/Application Support/BetterCalendarResearch');
  const c=['once','watch'].includes(mode)?credentials():{},recorder=new Recorder(root,{secrets:[c.platformToken,c.deviceToken]});
  if(mode==='export'){console.log(encode(recorder.export(args[0] ?? join(root,'export-'+Date.now()+'.json'))));return;}
  if(mode==='stats'){console.log(encode(recorder.stats()));return;}
  if(mode==='view'){console.log(encode({file:recorder.view()}));return;}
  if(mode==='replay'){console.log(encode(recorder.replay(args[0])));return;}
  if(mode==='prune'){console.log(encode(recorder.prune()));return;}
  if(mode==='stop'){writeFileSync(join(root,'STOP'),'stop requested',{mode:0o600});console.log('{"stopRequested":true}');return;}
  if(!['once','watch'].includes(mode))throw Error('unknown mode');
    const client=clientFor(c);do {
    try{const result=await recorder.tick(client);console.log(encode({at:new Date().toISOString(),...result}));if(result.stopped)break;}
    catch(e){if(mode!=='watch'||[401,403].includes(e.status)||e.message.includes('capacity'))throw e;console.error(encode({at:new Date().toISOString(),error:'collection_failed_retry_same_cursor',completed:false}));}
    if(mode==='watch')await new Promise(resolve=>setTimeout(resolve,recorder.config.pollSeconds*1000));
  }while(mode==='watch');
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href)main().catch(e=>{console.error(encode({error:e.message,completed:false}));process.exitCode=1;});
