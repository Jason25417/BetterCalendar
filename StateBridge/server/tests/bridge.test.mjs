import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { createBridge, signWebhook, validateCallback } from '../lib/bridge.mjs';
import { sourceView } from '../lib/state-view.mjs';
function fixture(options={}){
 const sqlite=new DatabaseSync(':memory:');for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort()) sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 function prepare(sql){let args=[];return {bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return {results:sqlite.prepare(sql).all(...args)};},run(){return sqlite.prepare(sql).run(...args);}};}
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const r=ops.map(o=>o.run());sqlite.exec('COMMIT');return r;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 let clock=new Date('2026-10-05T12:00:00Z'),posts=[],fail=false,redirectReceiver=false;
 const fetcher=async(url,opts)=>{assert.equal(opts.redirect,'manual','edge-compatible redirect mode');if(url.includes('dns-query'))return Response.json({Status:0,Answer:[{type:1,data:'104.18.1.1'}]});posts.push({url,...opts});if(redirectReceiver)return new Response('',{status:302,headers:{Location:'https://127.0.0.1/private'}});if(fail)return new Response('',{status:503});let data=JSON.parse(opts.body);return Response.json(data.type==='verification'?{challenge:data.challenge}:{});};
 const core=createBridge(db,{now:()=>clock,fetcher,...options});
 return {core,sqlite,posts,advance(ms){clock=new Date(clock.getTime()+ms);},setFail(v){fail=v;},setReceiverRedirect(v){redirectReceiver=v;},time(){return clock.toISOString();}};
}
const obs=(seq,value,f,extra={})=>({schemaVersion:1,eventId:`test-${seq}`,source:'mac.activity',sequence:seq,observedAt:f.time(),expiresAt:new Date(Date.parse(f.time())+90000).toISOString(),assertion:'observed',value,...extra});
async function device(f){const d=await f.core.registerDevice({id:'mac',label:'test',scopes:['mac.activity']});return f.core.authenticateDevice(d.token);}
test('outbox replay, scope, changed value, old data cannot overwrite and stale recovers',async()=>{
 const f=fixture(),d=await device(f),one=obs(1,{app:'editor'},f);await f.core.ingest({observations:[one]},d);await f.core.ingest({observations:[one]},d);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM observations').get().n,1);
 await assert.rejects(f.core.ingest({observations:[{...one,value:'collision'}]},d),/不能复用/);
 f.advance(60000);await f.core.ingest({observations:[obs(2,{app:'editor'},f)]},d);assert.equal((await f.core.readChanges()).changes.length,1);
 await f.core.ingest({observations:[obs(1,'old',f,{eventId:'late',observedAt:'2026-10-05T11:00:00Z'})]},d);assert.deepEqual((await f.core.readState()).sources[0].value,{app:'editor'});
 await assert.rejects(f.core.ingest({observations:[obs(3,1,f,{source:'health.sleep'})]},d),/权限/);
 f.advance(120000);assert.equal((await f.core.readState()).sources[0].freshness,'stale');await f.core.flush();assert.equal((await f.core.readChanges()).changes.at(-1).observation.freshness,'stale');
 await f.core.ingest({observations:[obs(4,{app:'editor'},f)]},d);assert.equal((await f.core.readState()).sources[0].freshness,'current');
});
test('persistent timing, pauses, duplicates, concurrency revision and inferred observations',async()=>{
 const f=fixture(),v={commandId:'start',action:'start',title:'数学',provenance:'user'};
 const s=await f.core.taskCommand(v);f.advance(120000);assert.equal((await f.core.readState()).sessions[0].elapsedMs,120000);assert.equal((await f.core.taskCommand(v)).id,s.id);
 const paused=await f.core.taskCommand({commandId:'pause',action:'pause',sessionId:s.id,expectedRevision:1,provenance:'user'});assert.equal(paused.elapsedMs,120000);f.advance(300000);assert.equal((await f.core.readState()).sessions[0].elapsedMs,120000);
 await assert.rejects(f.core.taskCommand({commandId:'bad',action:'resume',sessionId:s.id,expectedRevision:1,provenance:'user'}),/状态已变/);
 await f.core.taskCommand({commandId:'resume',action:'resume',sessionId:s.id,expectedRevision:2,provenance:'user'});f.advance(60000);
 const done=await f.core.taskCommand({commandId:'end',action:'finish',sessionId:s.id,expectedRevision:3,provenance:'user'});assert.equal(done.elapsedMs,180000);assert.equal((await f.core.readState()).sessions.length,0);assert.equal((await f.core.taskHistory()).sessions[0].elapsedMs,180000);
 await assert.rejects(f.core.taskCommand({...v,commandId:'infer',provenance:'inferred'}),/仅接受用户/);
});

test('native and MCP actions share one timing record, preserve legacy link, and reject stale device revisions',async()=>{
 const f=fixture();const start={commandId:'native-start',action:'start',title:'测试计时',provenance:'user',relatedRecordId:'PlanBlock:legacy-id'};
 const s=await f.core.taskCommand(start,'device:mac');assert.equal(s.saved,true);assert.equal(s.commandId,start.commandId);
 f.advance(120000);let state=await f.core.taskState();assert.equal(state.authority,'bettercalendar');assert.equal(state.sessions.length,1);assert.equal(state.sessions[0].elapsedMs,120000);assert.equal(state.sessions[0].relatedRecordId,start.relatedRecordId);
 const pause={commandId:'mcp-pause',action:'pause',sessionId:s.id,expectedRevision:1,provenance:'user'};
 const p=await f.core.taskCommand(pause);assert.equal(p.origin,'mcp');assert.equal(p.relatedRecordId,start.relatedRecordId);assert.equal((await f.core.taskCommand(pause)).revision,2);
 await assert.rejects(f.core.taskCommand({commandId:'late-device',action:'finish',sessionId:s.id,expectedRevision:1,provenance:'user'},'device:iphone'),/状态已变/);
 f.advance(60000);assert.equal((await f.core.taskState()).sessions[0].elapsedMs,120000);
 await f.core.taskCommand({commandId:'device-resume',action:'resume',sessionId:s.id,expectedRevision:2,provenance:'user'},'device:iphone');f.advance(30000);
 const done=await f.core.taskCommand({commandId:'native-finish',action:'finish',sessionId:s.id,expectedRevision:3,provenance:'user'},'device:mac');
 assert.equal(done.elapsedMs,150000);assert.equal((await f.core.taskState()).sessions.length,0);assert.equal((await f.core.taskHistory()).sessions[0].relatedRecordId,start.relatedRecordId);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,1);assert.ok((await f.core.readChanges()).changes.every(c=>c.sourceKey==='bc:tasks'));
});

test('development edits remain visible and cannot be overwritten using a stale revision',async()=>{
 const f=fixture(),s=await f.core.taskCommand({commandId:'before-edit',action:'start',title:'原题目',provenance:'user'});
 f.sqlite.prepare("UPDATE sessions SET title=?,status='paused',active_since=NULL,elapsed_ms=90000,revision=2 WHERE id=?").run('修正题目',s.id);
 const view=(await f.core.taskState()).sessions[0];assert.equal(view.title,'修正题目');assert.equal(view.status,'paused');assert.equal(view.elapsedMs,90000);
 await assert.rejects(f.core.taskCommand({commandId:'old-revision',action:'pause',sessionId:s.id,expectedRevision:1,provenance:'user'}),/状态已变/);
 assert.equal(JSON.parse(f.sqlite.prepare('SELECT result FROM commands WHERE id=?').get('before-edit').result).title,'原题目');
});

test('metadata reads retain coverage while selected values remain available',async()=>{
 const f=fixture(),d=await device(f);await f.core.ingest({observations:[obs(1,{app:'editor'},f)]},d);
 await f.core.recordNote({id:'note',kind:'intent',body:{privateText:'content'},assertion:'user',confidence:'high',basis:[]});
 const meta=await f.core.readState({includeValues:false});assert.equal(meta.valuesIncluded,false);assert.equal(meta.sourceCount,1);assert.equal(meta.sources[0].value,undefined);assert.equal(meta.notes[0].body,undefined);assert.equal(meta.coverage[0].sources[0].availability,'available');
 const detail=await f.core.readState({sourceKeys:[meta.sources[0].sourceKey]});assert.deepEqual(detail.sources[0].value,{app:'editor'});
 const absent=await f.core.readState({sourceKeys:['missing:key']});assert.equal(absent.sources.length,0);assert.deepEqual(absent.missingSourceKeys,['missing:key']);assert.equal(absent.coverage.length,1);
 await assert.rejects(f.core.readState({includeValues:'false'}),/布尔值/);
});

test('change pages keep complete observations and stop at the batch boundary',async()=>{
 const f=fixture(),d=await device(f),payload='x'.repeat(40000);
 for(let seq=1;seq<=5;seq++)await f.core.ingest({observations:[obs(seq,{payload,seq},f)]},d);
 const first=await f.core.readChanges(0,100,4);assert.equal(first.hasMore,true);assert.ok(JSON.stringify(first).length<128*1024);
 const second=await f.core.readChanges(first.nextCursor,100,4);assert.equal(second.hasMore,false);assert.deepEqual([...first.changes,...second.changes].map(c=>c.id),[1,2,3,4]);
 assert.ok([...first.changes,...second.changes].every(c=>c.observation.value.payload===payload));
 const nextBatch=await f.core.readChanges(second.nextCursor,100,5);assert.deepEqual(nextBatch.changes.map(c=>c.id),[5]);
});
test('minute batches, stable webhook id, retry and no changes no batch',async()=>{
 const f=fixture(),d=await device(f),secret='whsec_'+Buffer.alloc(32,7).toString('base64');
 const sub=await f.core.subscribe({name:'state.minute_changed',arguments:{},delivery:{mode:'webhook',url:'https://api.openai.com/test-callback',secret}},'owner');assert.ok(sub.refreshBefore);
 await f.core.ingest({observations:[obs(1,'editor',f)]},d);f.setFail(true);const a=await f.core.flush();assert.equal(a.delivered,0);
 f.advance(60000);f.setFail(false);const b=await f.core.flush();assert.equal(b.batchId,null);assert.equal(b.delivered,1);
 const sends=f.posts.filter(p=>!JSON.parse(p.body).type);assert.equal(sends[0].headers['webhook-id'],sends[1].headers['webhook-id']);assert.notEqual(sends[0].headers['webhook-timestamp'],sends[1].headers['webhook-timestamp']);
 assert.equal(sends[1].headers['webhook-signature'],await signWebhook(secret,sends[1].headers['webhook-id'],sends[1].headers['webhook-timestamp'],sends[1].body));
 assert.equal((await f.core.flush()).delivered,0);await f.core.acknowledgeBatch(a.batchId,'owner');assert.ok((await f.core.diagnostics()).batches[0].processed_at);
 await assert.rejects(validateCallback('https://127.0.0.1/'),/仅接受/);await assert.rejects(validateCallback('https://evil.test/'),/仅接受/);
});
test('correction supersedes inference without removing history',async()=>{
 const f=fixture();await f.core.recordNote({id:'guess',kind:'activity',body:{state:'rest'},assertion:'inferred',confidence:'low',basis:['sensor:test']});
 await f.core.recordNote({id:'correction',kind:'activity',body:{state:'reading'},assertion:'user',confidence:'high',basis:[],supersedes:'guess'});
 assert.equal((await f.core.readState()).notes.length,1);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM notes').get().n,2);
});

test('observation history paginates equal timestamps, preserves unknown versions, and does not rewrite states',async()=>{
 const f=fixture(),d=await device(f);
 for(const [seq,id] of [[1,'记录-甲'],[2,'记录-乙'],[3,'记录-丙']]) await f.core.ingest({observations:[obs(seq,{app:id},f,{eventId:id})]},d);
 // An upgraded envelope already present in storage must remain readable.
 const body={schemaVersion:8,extension:{future:'kept'},value:{app:'future'},observedAt:f.time()};
 f.sqlite.prepare('INSERT INTO observations(id,source_key,device_id,seq,observed_at,received_at,body) VALUES(?,?,?,?,?,?,?)').run('future','mac:mac.activity','mac',4,f.time(),f.time(),JSON.stringify(body));
 const beforeState=await f.core.readState();
 let cursor=null,ids=[],pages=[];
 do {const page=await f.core.readObservationHistory({sourceKey:'mac:mac.activity',limit:1,...(cursor?{cursor}: {})});ids.push(...page.observations.map(o=>o.eventId));pages.push(page);cursor=page.nextCursor;f.advance(1000);} while(cursor);
 assert.equal(ids.length,4);assert.equal(new Set(ids).size,4);assert.deepEqual(pages[0].observations[0].observation,body);
 assert.ok(pages.every(p=>p.before===pages[0].before));assert.equal(pages.at(-1).hasMore,false);
 assert.deepEqual((await f.core.readState()).sources.map(s=>s.eventId),beforeState.sources.map(s=>s.eventId));
 await assert.rejects(f.core.readObservationHistory({sourceKey:'other',cursor:pages[0].nextCursor}),/游标/);
 await assert.rejects(f.core.readObservationHistory({sourceKey:'mac:mac.activity',cursor:pages[0].nextCursor,before:f.time()}),/游标/);
 await assert.rejects(f.core.readObservationHistory({sourceKey:'mac:mac.activity',limit:0}),/每页/);
 await assert.rejects(f.core.readObservationHistory({sourceKey:'mac:mac.activity',from:f.time(),before:'2026-10-05T11:00:00Z'}),/开始时间/);
});

test('history orders delayed evidence by occurrence, keeps receive time, and bounds each source',async()=>{
 const f=fixture(),d=await device(f);await f.core.ingest({observations:[obs(1,'now',f)]},d);
 f.advance(60000);await f.core.ingest({observations:[obs(2,'late',f,{eventId:'late-history',observedAt:'2026-10-05T11:00:00Z'})]},d);
 const history=await f.core.readObservationHistory({sourceKey:'mac:mac.activity'});
 assert.equal(history.observations[0].eventId,'late-history');assert.equal(history.observations[0].receivedAt,f.time());
 assert.equal((await f.core.readState()).sources[0].value,'now');
 assert.equal((await f.core.readObservationHistory({sourceKey:'mac:mac.activity',from:'2026-10-05T12:00:00Z'})).observations.length,1);
 assert.equal((await f.core.readObservationHistory({sourceKey:'missing:mac.activity'})).observations.length,0);
 await assert.rejects(f.core.readObservationHistory({sourceKey:'mac:mac.activity',cursor:'broken'}),/游标/);
});

test('history byte budget paginates without cutting raw entries and late uploads require a new query',async()=>{
 const f=fixture(),d=await device(f);const payload='x'.repeat(40000);
 for(let seq=1;seq<=6;seq++) await f.core.ingest({observations:[obs(seq,{payload,seq},f)]},d);
 const first=await f.core.readObservationHistory({sourceKey:'mac:mac.activity',limit:100});
 assert.equal(first.hasMore,true);assert.ok(JSON.stringify(first).length<180*1024);
 f.advance(1000);await f.core.ingest({observations:[obs(7,{payload,seq:7},f,{observedAt:'2026-10-05T12:00:00Z'})]},d);
 const next=await f.core.readObservationHistory({sourceKey:'mac:mac.activity',limit:100,cursor:first.nextCursor});
 assert.equal(next.hasMore,false);assert.equal(first.observations.length+next.observations.length,6);assert.ok(next.observations.every(o=>o.observation.value.payload===payload));
 const reread=await f.core.readObservationHistory({sourceKey:'mac:mac.activity',limit:100});
 const rereadNext=await f.core.readObservationHistory({sourceKey:'mac:mac.activity',limit:100,cursor:reread.nextCursor});
 assert.equal(reread.observations.length+rereadNext.observations.length,7);
});

test('history index migration preserves legacy evidence byte for byte and supports bounded lookup',()=>{
 const sqlite=new DatabaseSync(':memory:');
 for(const file of ['0000_red_mathemanic.sql','0001_narrow_loners.sql','0002_colorful_bloodscream.sql']) sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 const body='{ "schemaVersion": 1, "legacyExtra": {"kept": true}, "value": "原记录" }';
 sqlite.prepare('INSERT INTO observations(id,source_key,device_id,seq,observed_at,received_at,body) VALUES(?,?,?,?,?,?,?)').run('old','mac:mac.activity','mac',1,'2026-10-05T12:00:00Z','2026-10-05T12:01:00Z',body);
 const before=sqlite.prepare('SELECT * FROM observations').all();
 sqlite.exec(readFileSync(new URL('../drizzle/0003_funny_unicorn.sql',import.meta.url),'utf8'));
 assert.deepEqual(sqlite.prepare('SELECT * FROM observations').all(),before);
 const plan=sqlite.prepare('EXPLAIN QUERY PLAN SELECT * FROM observations WHERE source_key=? AND observed_at>=? AND observed_at<=? ORDER BY observed_at,id LIMIT 31').all('mac:mac.activity','2026-10-05T00:00:00Z','2026-10-06T00:00:00Z');
 assert.ok(plan.some(row=>row.detail.includes('idx_observations_source_time')));sqlite.close();
});

test('state coverage separates fresh errors, empty samples, missing sources and old successful data',async()=>{
 const f=fixture();const enrolled=await f.core.registerDevice({id:'iphone',label:'test',scopes:['health.status','health.sleep','ios.app','calendar.events']});const d=await f.core.authenticateDevice(enrolled.token);
 const input=(seq,source,value)=>obs(seq,value,f,{source,eventId:`coverage-${seq}`});
 await f.core.ingest({observations:[input(1,'health.status',{availability:'read-unavailable'})]},d);
 f.advance(1000);await f.core.ingest({observations:[input(2,'health.sleep',{samples:[{stage:1}],availability:'readable'}),input(3,'calendar.events',{items:[],truncated:false})]},d);
 const state=await f.core.readState(),status=state.sources.find(s=>s.source==='health.status');
 assert.equal(status.freshness,'current');assert.equal(status.availability,'error');assert.equal(status.usableForCurrentState,false);
 assert.equal(state.coverage[0].sources.find(s=>s.source==='ios.app').availability,'not_received');
 assert.equal(state.sources.find(s=>s.source==='calendar.events').availability,'empty');assert.equal(state.warnings[0].code,'health_summary_older_than_samples');
 f.advance(100000);const stale=await f.core.readState();assert.equal(stale.sources.find(s=>s.source==='health.sleep').usableForCurrentState,false);assert.equal(stale.warnings.length,0);
 await f.core.ingest({observations:[input(4,'health.sleep',{samples:[],availability:'no-readable-samples-not-proof-of-no-sleep'})]},d);
 assert.equal((await f.core.readState()).sources.find(s=>s.source==='health.sleep').availability,'unknown');
});

test('empty truncated or failed snapshots never claim a complete empty result',()=>{
 const base={source:'calendar.events',observedAt:'2026-10-05T12:00:00Z',expiresAt:'2026-10-05T13:00:00Z'};
 for(const value of [{availability:'partial',items:[],truncated:true,omittedItems:1},{items:[],truncated:true},{availability:'partial',items:[]}]){
  const view=sourceView({...base,value},'mac:calendar.events','2026-10-05T12:01:00Z');assert.equal(view.availability,'partial');
 }
 const error=sourceView({...base,value:{availability:'read-unavailable',items:[]}},'mac:calendar.events','2026-10-05T12:01:00Z');
 assert.equal(error.availability,'error');assert.equal(error.usableForCurrentState,false);
});

test('default policy forwards every valid change and does not create batches for unchanged heartbeats',async()=>{
 const f=fixture(),d=await device(f);await f.core.ingest({observations:[obs(1,'editor',f)]},d);
 const a=await f.core.flush();assert.equal(a.decision.policy,'ForwardAllToDots');
 const saved=JSON.parse(f.sqlite.prepare('SELECT body FROM batches WHERE id=?').get(a.batchId).body);assert.equal(saved.data.changes.length,1);assert.equal(saved.data.decision.forward,true);
 f.advance(60000);await f.core.ingest({observations:[obs(2,'editor',f)]},d);assert.equal((await f.core.flush()).batchId,null);
});

test('decision interface can defer without losing changes or blocking older delivery retries',async()=>{
 let forward=true;const f=fixture({decisionPolicy:{async decide(){return {forward,policy:'TestPolicy'};}}}),d=await device(f),secret='whsec_'+Buffer.alloc(32,7).toString('base64');
 await f.core.subscribe({name:'state.minute_changed',arguments:{},delivery:{mode:'webhook',url:'https://api.openai.com/test-callback',secret}},'owner');
 await f.core.ingest({observations:[obs(1,'editor',f)]},d);f.setFail(true);await f.core.flush();
 f.advance(60000);await f.core.ingest({observations:[obs(2,'browser',f)]},d);forward=false;f.setFail(false);
 const deferred=await f.core.flush();assert.equal(deferred.batchId,null);assert.equal(deferred.deferred,true);assert.equal(deferred.delivered,1);
 forward=true;const resumed=await f.core.flush();assert.ok(resumed.batchId);const body=JSON.parse(f.sqlite.prepare('SELECT body FROM batches WHERE id=?').get(resumed.batchId).body);assert.equal(body.data.changes[0].observation.value,'browser');
});
test('DNS and receiver redirects cannot bypass callback checks on Workers',async()=>{
 const f=fixture(),secret='whsec_'+Buffer.alloc(32,9).toString('base64');
 await assert.rejects(validateCallback('https://connectors.api.openai.com/',async(_url,options)=>{assert.equal(options.redirect,'manual');return new Response('',{status:302,headers:{Location:'https://127.0.0.1/private'}});}),/无法验证回调 DNS/);
 f.setReceiverRedirect(true);
 await assert.rejects(f.core.subscribe({name:'state.minute_changed',arguments:{},delivery:{mode:'webhook',url:'https://connectors.api.openai.com/callback',secret}},'owner'),error=>error.reason==='invalid_url');
 assert.equal(f.posts.length,1);
 assert.equal((await f.core.diagnostics()).subscriptions.length,0);
 f.setReceiverRedirect(false);await f.core.subscribe({name:'state.minute_changed',arguments:{},delivery:{mode:'webhook',url:'https://connectors.api.openai.com/callback',secret}},'owner');
 await f.core.ingest({observations:[obs(1,'editor',f)]},await device(f));f.setReceiverRedirect(true);
 assert.equal((await f.core.flush()).delivered,0);
 assert.equal((await f.core.diagnostics()).deliveries[0].status,'pending');
 assert.ok(f.posts.every(p=>p.url.startsWith('https://connectors.api.openai.com/')));
});

test('timing history pages beyond 100 without losing equal timestamps or admitting late inserts',async()=>{
 const f=fixture();
 for(let i=0;i<105;i++)await f.core.taskCommand({commandId:`start-${i}`,action:'start',title:`事项${i}`,provenance:'user'});
 const first=await f.core.taskHistory({limit:60});assert.equal(first.sessions.length,60);assert.equal(first.hasMore,true);
 await f.core.taskCommand({commandId:'late-start',action:'start',title:'晚到',provenance:'user'});
 const second=await f.core.taskHistory({limit:60,cursor:first.nextCursor});assert.equal(second.sessions.length,45);assert.equal(second.hasMore,false);assert.equal(second.nextCursor,null);
 const ids=[...first.sessions,...second.sessions].map(s=>s.id);assert.equal(new Set(ids).size,105);
 assert.equal((await f.core.taskHistory({limit:100})).hasMore,true);
 await assert.rejects(f.core.taskHistory({limit:1.5}),/每页/);
 await assert.rejects(f.core.taskHistory({cursor:first.nextCursor,from:'2026-10-04T00:00:00Z'}),/游标/);
});

test('original command receipts survive state updates, paginate, and retain future fields',async()=>{
 const f=fixture(),s=await f.core.taskCommand({commandId:'开始-数学',action:'start',title:'数学',provenance:'user'});
 f.advance(60000);await f.core.taskCommand({commandId:'暂停-数学',action:'pause',sessionId:s.id,expectedRevision:1,provenance:'user'});
 f.advance(60000);await f.core.taskCommand({commandId:'结束-数学',action:'finish',sessionId:s.id,expectedRevision:2,provenance:'user'});
 const old=JSON.parse(f.sqlite.prepare('SELECT result FROM commands WHERE id=?').get('开始-数学').result);old.futureEnvelope={version:99,preserved:true};
 const bytes=JSON.stringify(old);f.sqlite.prepare('UPDATE commands SET result=? WHERE id=?').run(bytes,'开始-数学');
 const first=await f.core.readTaskCommands({sessionId:s.id,limit:2});assert.equal(first.hasMore,true);
 const second=await f.core.readTaskCommands({sessionId:s.id,limit:2,cursor:first.nextCursor});assert.equal(second.hasMore,false);
 assert.deepEqual([...first.commands,...second.commands].map(c=>c.commandId),['结束-数学','暂停-数学','开始-数学']);
 assert.equal(second.commands[0].result.status,'running');assert.equal(second.commands[0].result.revision,1);assert.deepEqual(second.commands[0].result.futureEnvelope,old.futureEnvelope);
 assert.equal(second.commands[0].request_hash,undefined);assert.equal(f.sqlite.prepare('SELECT result FROM commands WHERE id=?').get('开始-数学').result,bytes);
 await assert.rejects(f.core.readTaskCommands({sessionId:'other',cursor:first.nextCursor}),/游标/);
 await assert.rejects(f.core.taskHistory({cursor:first.nextCursor}),/游标/);
 assert.equal((await f.core.taskHistory()).sessions[0].status,'finished');
});

test('oversized receipt pages preserve complete records and signal continuation',async()=>{
 const f=fixture();
 for(let i=0;i<4;i++){
  const s=await f.core.taskCommand({commandId:`wide-${i}`,action:'start',title:'测试',provenance:'user'});
  const receipt={...s,futureText:'x'.repeat(44000)};f.sqlite.prepare('UPDATE commands SET result=? WHERE id=?').run(JSON.stringify(receipt),`wide-${i}`);
 }
 const first=await f.core.readTaskCommands();assert.equal(first.commands.length,2);assert.equal(first.hasMore,true);
 const second=await f.core.readTaskCommands({cursor:first.nextCursor});assert.equal(second.hasMore,false);
 assert.equal([...first.commands,...second.commands].length,4);assert.ok([...first.commands,...second.commands].every(c=>c.result.futureText.length===44000));
});

test('legacy resting-heart-rate null is unknown rather than available',()=>{
 const base={deviceId:'phone',source:'health.resting-heart-rate',observedAt:'2026-10-05T12:00:00Z',receivedAt:'2026-10-05T12:00:01Z',expiresAt:'2026-10-06T12:00:00Z'};
 for(const value of [{bpm:null},{bpm:null,availability:'readable'},[]]){
   const view=sourceView({...base,value},'phone:health.resting-heart-rate','2026-10-05T12:01:00Z');
   assert.equal(view.availability,'unknown');assert.equal(view.usableForCurrentState,false);
 }
 for(const value of [{bpm:62},[{bpm:62,end:'2026-10-05T12:00:00Z'}]]){
   assert.equal(sourceView({...base,value},'phone:health.resting-heart-rate','2026-10-05T12:01:00Z').availability,'available');
 }
 const failure=sourceView({...base,value:{availability:'read-unavailable',bpm:null}},'phone:health.resting-heart-rate','2026-10-05T12:01:00Z');
 assert.equal(failure.availability,'error');
});
