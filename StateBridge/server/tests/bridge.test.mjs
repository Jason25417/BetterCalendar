import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { createBridge, signWebhook, validateCallback } from '../lib/bridge.mjs';
import { sourceView } from '../lib/state-view.mjs';
import { shadowDecision } from '../lib/shadow-decision.mjs';
import { safeArguments } from '../lib/research.mjs';
function fixture(options={}){
 const sqlite=new DatabaseSync(':memory:');for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort()) sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 let failWrite=null;
 function prepare(sql){let args=[];return {bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return {results:sqlite.prepare(sql).all(...args)};},run(){if(failWrite?.(sql,args)){failWrite=null;throw Error('isolated write failure');}return sqlite.prepare(sql).run(...args);}};}
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const r=ops.map(o=>o.run());sqlite.exec('COMMIT');return r;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 let clock=new Date('2026-10-05T12:00:00Z'),posts=[],fail=false,redirectReceiver=false;
 const fetcher=async(url,opts)=>{assert.equal(opts.redirect,'manual','edge-compatible redirect mode');if(url.includes('dns-query'))return Response.json({Status:0,Answer:[{type:1,data:'104.18.1.1'}]});posts.push({url,...opts});if(redirectReceiver)return new Response('',{status:302,headers:{Location:'https://127.0.0.1/private'}});if(fail)return new Response('',{status:503});let data=JSON.parse(opts.body);return Response.json(data.type==='verification'?{challenge:data.challenge}:{});};
 const reopen=()=>createBridge(db,{now:()=>clock,fetcher,...options}),core=reopen();
 return {core,sqlite,posts,reopen,failNextWrite(predicate){failWrite=predicate;},advance(ms){clock=new Date(clock.getTime()+ms);},setFail(v){fail=v;},setReceiverRedirect(v){redirectReceiver=v;},time(){return clock.toISOString();}};
}
const obs=(seq,value,f,extra={})=>({schemaVersion:1,eventId:`test-${seq}`,source:'mac.activity',sequence:seq,observedAt:f.time(),expiresAt:new Date(Date.parse(f.time())+90000).toISOString(),assertion:'observed',value,...extra});
test('device receipts require offered complete snapshot, keep finish, and do not imply screen delivery',async()=>{
 const f=fixture();const enrolled=await f.core.registerDevice({id:'reader',label:'Reader',scopes:['user.context']});const d=await f.core.authenticateDevice(enrolled.token);
 const s=await f.core.taskCommand({commandId:'receipt-start',action:'start',title:'fixture only',provenance:'user'});
 let state=await f.core.taskState(d);const id=state.applicationSnapshot.id;
 assert.equal((await f.core.readTaskCommands()).commands[0].deviceApplication,'unknown');
 await assert.rejects(f.core.taskApplication.acknowledge({snapshotIds:[id,'missing']},d),/不属于/);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='task_snapshot_applied'").get().n,0);
 await f.core.taskApplication.acknowledge({snapshotIds:[id]},d);
 await f.core.taskApplication.acknowledge({snapshotIds:[id]},d); // lost response replay
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='task_snapshot_applied'").get().n,1);
 const command=(await f.core.readTaskCommands()).commands[0];assert.equal(command.deviceReceipts[0].deviceId,'reader');assert.equal(command.deviceReceipts[0].revision,1);assert.equal(command.userSeen,'unknown');
 await f.core.taskCommand({commandId:'receipt-finish',action:'finish',sessionId:s.id,expectedRevision:1,provenance:'user'});
 state=await f.core.taskState(d);assert.equal(state.sessions.length,0);assert.equal(state.applicationSnapshot.finishedVersions[0].commandId,'receipt-finish');
 await f.core.taskApplication.acknowledge({snapshotIds:[state.applicationSnapshot.id]},d);
 assert.equal((await f.core.readTaskCommands()).commands.find(c=>c.commandId==='receipt-finish').deviceReceipts[0].status,'finished');
 await f.core.revokeDevice(d.id);await assert.rejects(f.core.taskApplication.acknowledge({snapshotIds:[id]},d),/权限已撤回/);
});
test('snapshot receipts cannot cross devices or confirm a truncated active list',async()=>{
 const f=fixture();let ds=[];for(const id of ['a','b']){const c=await f.core.registerDevice({id,label:id,scopes:['user.context']});ds.push(await f.core.authenticateDevice(c.token));}
 const state=await f.core.taskState(ds[0]);await assert.rejects(f.core.taskApplication.acknowledge({snapshotIds:[state.applicationSnapshot.id]},ds[1]),/不属于/);
 const incomplete=await f.core.taskApplication.offer({...state,hasMore:true},ds[0],[]);
 await assert.rejects(f.core.taskApplication.acknowledge({snapshotIds:[incomplete.applicationSnapshot.id]},ds[0]),/未完整读取/);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,0);
});
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
test('concurrent service instances cannot send the same pending callback while one is in flight',async()=>{
 let release,entered;
 const gate=new Promise(r=>release=r),sending=new Promise(r=>entered=r),posts=[];
 const f=fixture({fetcher:async(url,options)=>{
  if(url.includes('dns-query'))return Response.json({Status:0,Answer:[{type:1,data:'104.18.1.1'}]});
  const body=JSON.parse(options.body);
  if(body.type==='verification')return Response.json({challenge:body.challenge});
  posts.push(options);entered();if(posts.length===1)await gate;
  return Response.json({});
 }});
 const d=await device(f);
 await f.core.subscribe({name:'state.minute_changed',arguments:{},delivery:{mode:'webhook',url:'https://api.openai.com/isolated-callback',secret:'whsec_'+Buffer.alloc(32,7).toString('base64')}},'owner');
 await f.core.ingest({observations:[obs(1,'isolated activity',f)]},d);
 const first=f.core.flush();await sending;
 let second;try{second=await f.reopen().flush();}finally{release();}
 const result=await first;
 assert.equal(posts.length,1,'one callback per live attempt across instances');
 assert.equal(second.delivered,0);assert.equal(result.delivered,1);
 assert.equal((await f.reopen().flush()).delivered,0);
 assert.equal(f.sqlite.prepare('SELECT attempts FROM deliveries').get().attempts,1);
});
async function subscribedFixture(f){
 const d=await device(f);
 await f.core.subscribe({name:'state.minute_changed',arguments:{},delivery:{mode:'webhook',url:'https://api.openai.com/isolated-callback',secret:'whsec_'+Buffer.alloc(32,7).toString('base64')}},'owner');
 await f.core.ingest({observations:[obs(1,'isolated activity',f,{expiresAt:null})]},d);
 return d;
}
test('failed attempt logging sends nothing and restart recovers the durable lease without discarding the batch',async()=>{
 const f=fixture();await subscribedFixture(f);
 f.failNextWrite((sql,args)=>sql.startsWith('INSERT INTO research_log')&&args[1]==='callback_attempt_started');
 await assert.rejects(f.core.flush(),/isolated write failure/);
 assert.equal(f.posts.filter(p=>!JSON.parse(p.body).type).length,0);
 assert.equal((await f.reopen().flush()).delivered,0);f.advance(60001);
 assert.equal((await f.reopen().flush()).delivered,1);
 assert.equal(f.posts.filter(p=>!JSON.parse(p.body).type).length,1);
 assert.equal(f.sqlite.prepare('SELECT attempts,status FROM deliveries').get().attempts,2);
});
test('successful receiver response with failed persistence stays unknown and retries with the same webhook identity',async()=>{
 const f=fixture();await subscribedFixture(f);
 f.failNextWrite((sql,args)=>sql.startsWith('UPDATE deliveries SET status=?')&&args[0]==='received');
 await assert.rejects(f.core.flush(),/isolated write failure/);
 assert.equal(f.sqlite.prepare('SELECT status,received_at FROM deliveries').get().status,'pending');
 assert.equal(f.sqlite.prepare('SELECT status,received_at FROM deliveries').get().received_at,null);
 assert.equal((await f.reopen().flush()).delivered,0);f.advance(60001);
 assert.equal((await f.reopen().flush()).delivered,1);
 const sends=f.posts.filter(p=>!JSON.parse(p.body).type);assert.equal(sends.length,2);
 assert.equal(sends[0].headers['webhook-id'],sends[1].headers['webhook-id']);assert.equal(sends[0].body,sends[1].body);
});
test('stale in-flight completion cannot overwrite a newer retry result after its lease was recovered',async()=>{
 let release,entered,count=0;
 const gate=new Promise(r=>release=r),sending=new Promise(r=>entered=r);
 const f=fixture({fetcher:async(url,options)=>{
  if(url.includes('dns-query'))return Response.json({Status:0,Answer:[{type:1,data:'104.18.1.1'}]});
  const body=JSON.parse(options.body);if(body.type==='verification')return Response.json({challenge:body.challenge});
  if(++count===1){entered();await gate;return Response.json({});}
  return new Response('',{status:503});
 }});
 await subscribedFixture(f);const first=f.core.flush();await sending;f.advance(60001);
 let newer;try{newer=await f.reopen().flush();}finally{release();}
 const old=await first;assert.equal(old.delivered,0);assert.equal(newer.delivered,0);
 const stored=f.sqlite.prepare('SELECT status,attempts,received_at,last_error FROM deliveries').get();
 assert.equal(stored.status,'pending');assert.equal(stored.attempts,2);assert.equal(stored.received_at,null);assert.equal(stored.last_error,'HTTP 503');
 const trace=(await f.core.research.read({limit:100})).entries.filter(e=>e.kind==='callback_attempt_finished');
 assert.ok(trace.some(e=>e.body.attempt===1&&e.body.outcome==='superseded'&&e.body.receiverAccepted===true));
});
test('attempt result logging failure is reported but a durably received callback is not resent',async()=>{
 const f=fixture();await subscribedFixture(f);
 f.failNextWrite((sql,args)=>sql.startsWith('INSERT INTO research_log')&&args[1]==='callback_attempt_finished');
 await assert.rejects(f.core.flush(),/isolated write failure/);
 assert.equal(f.sqlite.prepare('SELECT status FROM deliveries').get().status,'received');
 f.advance(60001);assert.equal((await f.reopen().flush()).delivered,0);
 assert.equal(f.posts.filter(p=>!JSON.parse(p.body).type).length,1);
});
test('subscription removal before lease acquisition cannot send and exhausted abandoned leases stop retrying',async()=>{
 const f=fixture();await subscribedFixture(f);f.setFail(true);await f.core.flush();
 await f.core.unsubscribe({name:'state.minute_changed',delivery:{url:'https://api.openai.com/isolated-callback'}},'owner');
 f.advance(60001);assert.equal((await f.reopen().flush()).delivered,0);
 assert.equal(f.posts.filter(p=>!JSON.parse(p.body).type).length,1);
 const second=fixture();await subscribedFixture(second);
 second.failNextWrite((sql,args)=>sql.startsWith('INSERT INTO research_log')&&args[1]==='callback_attempt_started');
 await assert.rejects(second.core.flush(),/isolated write failure/);
 second.sqlite.prepare('UPDATE deliveries SET attempts=8').run();second.advance(60001);
 assert.equal((await second.reopen().flush()).delivered,0);
 assert.equal(second.sqlite.prepare('SELECT status FROM deliveries').get().status,'failed');
 assert.equal(second.posts.filter(p=>!JSON.parse(p.body).type).length,0);
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

async function poolDevice(f,id='pool-mac'){
 const d=await f.core.registerDevice({id,label:'pool test',scopes:['user.context']});return f.core.authenticateDevice(d.token);
}
async function publishPool(f,d,records,{seq=1,eventPrefix='pool',manifestOnly=false,payloadVersion=1,executionSessions}={}){
 const payload={formatVersion:payloadVersion,authority:'swiftdata',dateUnit:'unix-milliseconds',records,...(executionSessions===undefined?{}:{executionSessions})};
 const bytes=Buffer.from(JSON.stringify(payload)),hash=Buffer.from(await crypto.subtle.digest('SHA-256',bytes)).toString('hex');
 const chunks=[];
 for(let i=0;i<bytes.length;i+=30*1024){chunks.push({schemaVersion:1,eventId:`${eventPrefix}-chunk-${chunks.length}`,source:'bc.pool.chunk',sequence:seq+chunks.length,assertion:'observed',observedAt:f.time(),expiresAt:'2027-10-05T12:00:00Z',value:{formatVersion:1,contentHash:hash,index:chunks.length,bytes:bytes.subarray(i,i+30*1024).toString('base64')}});}
 const manifest={schemaVersion:1,eventId:`${eventPrefix}-manifest`,source:'bc.pool',sequence:seq+chunks.length,assertion:'observed',observedAt:f.time(),expiresAt:new Date(Date.parse(f.time())+180000).toISOString(),value:{formatVersion:1,authority:'swiftdata',availability:'available',contentHash:hash,recordCount:records.length,chunkEventIds:chunks.map(c=>c.eventId),...(executionSessions===undefined?{}:{executionSessionCount:executionSessions.length})}};
 await f.core.uploadPool({observations:manifestOnly?[manifest]:[...chunks,manifest]},d);return {manifest,chunks};
}
const poolRecord=(id,extra={})=>({id,revision:'a'.repeat(64),values:{id,title:id,zone:'longterm',status:'active',isInTrash:false,note:'',...extra}});

test('pool upload is restricted to enrolled interactive devices, and unavailable is not empty',async()=>{
 const f=fixture(),ordinary=await device(f),d=await poolDevice(f);
 const missing=await f.core.readPoolRecords();assert.equal(missing.availability,'not_received');assert.equal(missing.complete,false);
 const coverage=(await f.core.readState({includeValues:false})).coverage.find(x=>x.deviceId===d.id);
 assert.equal(coverage.sources.find(x=>x.source==='bc.pool').availability,'not_received');
 await assert.rejects(publishPool(f,ordinary,[]),/事项权限/);
 const {manifest}=await publishPool(f,d,[]);const empty=await f.core.readPoolRecords();assert.equal(empty.complete,true);assert.equal(empty.totalRecordCount,0);assert.equal(empty.availability,'available');
 const fragment=(await f.core.readState({includeValues:false})).sources.find(x=>x.source==='bc.pool.chunk');
 assert.equal(fragment.dataRole,'record-fragment');assert.equal(fragment.usableForCurrentState,false);
 await assert.rejects(f.core.ingest({observations:[manifest]},d),/来源权限/);
 f.advance(60000);await f.core.uploadPool({observations:[{...manifest,eventId:'pool-read-error',sequence:50,observedAt:f.time(),value:{availability:'read-unavailable'}}]},d);
 const unavailable=await f.core.readPoolRecords();assert.equal(unavailable.complete,false);assert.equal(unavailable.availability,'error');
});
test('complete pool pagination pins content across device updates and retains future fields',async()=>{
 const f=fixture(),d=await poolDevice(f),records=Array.from({length:115},(_,i)=>poolRecord(`record-${i}`,{futureField:{keep:true}}));
 await publishPool(f,d,records);const first=await f.core.readPoolRecords({limit:40});assert.equal(first.records.length,40);assert.equal(first.hasMore,true);
 f.advance(60000);await publishPool(f,d,[poolRecord('new')],{seq:20,eventPrefix:'new'});
 const second=await f.core.readPoolRecords({limit:40,cursor:first.nextCursor}),third=await f.core.readPoolRecords({limit:40,cursor:second.nextCursor});
 assert.equal(third.hasMore,false);assert.equal(first.records.length+second.records.length+third.records.length,115);
 assert.equal(third.records.at(-1).values.futureField.keep,true);assert.equal((await f.core.readPoolRecords()).records[0].id,'new');
 await assert.rejects(f.core.readPoolRecords({cursor:first.nextCursor,zone:'todo'}),/游标/);
});
test('pool filtering preserves done, shelved, wishes and retained trash without merging device views',async()=>{
 const f=fixture(),mac=await poolDevice(f),phone=await poolDevice(f,'pool-phone');
 const records=[poolRecord('active'),poolRecord('done',{status:'done'}),poolRecord('shelved',{status:'shelved'}),poolRecord('wish',{zone:'todo'}),poolRecord('trash',{zone:'todo',isInTrash:true})];
 await publishPool(f,mac,records);f.advance(60000);await publishPool(f,phone,[poolRecord('phone-view')],{eventPrefix:'phone'});
 const all=await f.core.readPoolRecords({deviceId:mac.id,includeTrash:true});assert.equal(all.records.length,5);assert.equal(all.deviceViewsDiffer,true);
 const todo=await f.core.readPoolRecords({deviceId:mac.id,zone:'todo'});assert.deepEqual(todo.records.map(r=>r.id),['wish']);
 assert.equal((await f.core.readPoolRecords({deviceId:mac.id,status:'shelved'})).records[0].id,'shelved');
 f.advance(180000);assert.equal((await f.core.readPoolRecords({deviceId:mac.id})).freshness,'stale');assert.equal((await f.core.readPoolRecords({deviceId:mac.id})).usableForCurrentState,false);
});
test('pool missing fragments, checksum corruption, duplicate IDs and unknown format fail visibly',async()=>{
 let f=fixture(),d=await poolDevice(f);await publishPool(f,d,[poolRecord('a')],{manifestOnly:true});await assert.rejects(f.core.readPoolRecords(),/分片/);
 f=fixture();d=await poolDevice(f);const p=await publishPool(f,d,[poolRecord('a')]);
 const raw=JSON.parse(f.sqlite.prepare('SELECT body FROM observations WHERE id=?').get(p.chunks[0].eventId).body);raw.value.bytes=Buffer.from('different bytes').toString('base64');
 f.sqlite.prepare('UPDATE observations SET body=? WHERE id=?').run(JSON.stringify(raw),p.chunks[0].eventId);await assert.rejects(f.core.readPoolRecords(),/校验/);
 f=fixture();d=await poolDevice(f);await publishPool(f,d,[poolRecord('a'),poolRecord('a')]);await assert.rejects(f.core.readPoolRecords(),/身份/);
 f=fixture();d=await poolDevice(f);await publishPool(f,d,[poolRecord('a')],{payloadVersion:2});await assert.rejects(f.core.readPoolRecords(),/版本/);
});
test('pool fragmentation reconstructs UTF-8 notes, limits pages without losing oversized rows',async()=>{
 const f=fixture(),d=await poolDevice(f),text='学习🌲'.repeat(20000),records=[poolRecord('large',{note:text}),poolRecord('next')];
 await publishPool(f,d,records);const first=await f.core.readPoolRecords();assert.equal(first.records.length,1);assert.equal(first.records[0].values.note,text);assert.equal(first.byteBudgetExceeded,true);assert.equal(first.hasMore,true);
 const second=await f.core.readPoolRecords({cursor:first.nextCursor});assert.equal(second.records[0].id,'next');assert.equal(second.hasMore,false);
});

async function researchFixture() {
 const f=fixture(),d=await device(f);
 for(let seq=1;seq<=3;seq++)await f.core.ingest({observations:[obs(seq,{seq},f)]},d);
 const batch=await f.core.flush();return {...f,batch};
}
async function readForBatch(f,limit=100) {
 let after=0,calls=[];
 while(true){const p=await f.core.research.invoke('read_changes',{afterId:after,throughId:3,limit},'owner',()=>f.core.readChanges(after,limit,3));calls.push(p.research.callId);after=p.nextCursor;if(!p.hasMore)break;}
 const state=await f.core.research.invoke('read_current_state',{},'owner',()=>f.core.readState());calls.push(state.research.callId);return calls;
}
const completion=(f,calls)=>({batchId:f.batch.batchId,resultId:'same-result',readCallIds:calls,conclusions:[],notification:{channel:'silent',result:'not_requested'},operation:{kind:'none'}});
test('research complete rejects first page, persists full pages atomically and retries one result',async()=>{
 const f=await researchFixture();
 const p=await f.core.research.invoke('read_changes',{afterId:0,limit:1,throughId:3},'owner',()=>f.core.readChanges(0,1,3));
 await assert.rejects(f.core.research.complete(completion(f,[p.research.callId]),'owner'),/完整读取/);
 assert.equal(f.sqlite.prepare('SELECT processed_at FROM batches').get().processed_at,null);
 const calls=await readForBatch(f,1),input=completion(f,calls),r=await f.core.research.complete(input,'owner');
 assert.equal(r.recorded,true);assert.equal(r.deviceApplication,'unknown');
 assert.equal((await f.core.research.complete(input,'owner')).resultId,r.resultId);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='batch_result'").get().n,1);
 await assert.rejects(f.core.research.complete({...input,attention:{seconds:3}},'owner'),/不能复用/);
 await assert.rejects(f.core.research.complete({...input,resultId:'other'},'other-owner'),/不属于/);
});
test('research conclusions cite actual calls; silence cannot claim a notification; operation needs saved receipt',async()=>{
 const f=await researchFixture(),calls=await readForBatch(f),input=completion(f,calls);
 await assert.rejects(f.core.research.complete({...input,conclusions:[{summary:'猜测',sourceClass:'inference',confidence:'low',rationale:'活动不足',evidenceCallIds:['invented'],alternatives:[]}]},'owner'),/结论必须/);
 await assert.rejects(f.core.research.complete({...input,notification:{channel:'silent',result:'reported_sent'}},'owner'),/静默/);
 await assert.rejects(f.core.research.complete({...input,operation:{kind:'task_command',commandId:'invented'}},'owner'),/保存回执/);
 assert.equal((await f.core.research.complete({...input,conclusions:[{summary:'没有足够证据判断任务结束',sourceClass:'inference',confidence:'low',rationale:'只观察到应用变化',evidenceCallIds:[calls[0]],alternatives:['可能仍在纸上工作']}]},'owner')).userFeedback,'unknown');
});
test('recording fails before execution; response loss after actual saved command retries without double timing',async()=>{
 const f=fixture();f.sqlite.exec('DROP TABLE research_log');let executed=false;
 await assert.rejects(f.core.research.invoke('task_command',{},'owner',()=>{executed=true;return {};}));assert.equal(executed,false);
 const g=fixture(),v={commandId:'persist-loss',action:'start',title:'fixture',provenance:'user'};
 g.sqlite.exec("CREATE TRIGGER fail_return BEFORE INSERT ON research_log WHEN NEW.kind='call_returned' BEGIN SELECT RAISE(FAIL,'disk failure'); END");
 await assert.rejects(g.core.research.invoke('task_command',v,'owner',()=>g.core.taskCommand(v)),/disk failure/);
 assert.equal(g.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,1);
 g.sqlite.exec('DROP TRIGGER fail_return');const result=await g.core.research.invoke('task_command',v,'owner',()=>g.core.taskCommand(v));assert.equal(result.saved,true);
 assert.equal(g.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,1);
});
test('complete persistence failure cannot advance processed_at; correction preserves original receipt',async()=>{
 const f=await researchFixture(),calls=await readForBatch(f),input=completion(f,calls);
 f.sqlite.exec("CREATE TRIGGER fail_result BEFORE INSERT ON research_log WHEN NEW.kind='batch_result' BEGIN SELECT RAISE(FAIL,'disk failure'); END");
 await assert.rejects(f.core.research.complete(input,'owner'),/disk failure/);assert.equal(f.sqlite.prepare('SELECT processed_at FROM batches').get().processed_at,null);
 f.sqlite.exec('DROP TRIGGER fail_result');const first=await f.core.research.complete(input,'owner');
 await f.core.research.complete({...input,resultId:'correction',supersedes:first.resultId},'owner');
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='batch_result'").get().n,2);
});
test('research cursor freezes upper bound; no credential or raw body in metadata; revoked device denied',async()=>{
 const f=fixture(),d=await device(f);
 await f.core.research.invoke('read_current_state',{},'owner',()=>f.core.readState());
 const page=await f.core.research.read({limit:1});await f.core.research.invoke('read_current_state',{},'owner',()=>f.core.readState());
 const rest=await f.core.research.read({afterId:page.nextCursor,throughId:page.throughId});assert.equal(rest.entries.length,1);assert.equal(rest.hasMore,false);
 assert.deepEqual(safeArguments({token:'secret',body:{token:'secret'},commandId:'ok',basis:['Bearer secret']}),{commandId:'ok',basis:['[redacted]']});
 const enrolled=await f.core.registerDevice({id:'revoked',label:'fixture',scopes:['user.context']});await f.core.revokeDevice(enrolled.id);await assert.rejects(f.core.authenticateDevice(enrolled.token),/撤销/);
 const args={observations:[obs(1,{privateText:'original'},f)]};await f.core.research.invoke('ingest',args,'device:mac',()=>f.core.ingest(args,d));
 const logged=f.sqlite.prepare('SELECT body FROM research_log').all().map(r=>r.body).join('');assert.ok(!logged.includes('original'));assert.ok(logged.includes('test-1'));
});
test('shadow preserves errors and user commands; refresh filtering is pure and distinct from ForwardAll',()=>{
 const c=(id,value,extra={})=>({id,sourceKey:'mac:activity',observation:{eventId:String(id),assertion:'observed',value,...extra}});
 const first=shadowDecision([c(1,{app:'editor',sampledAt:'old'})]);
 const second=shadowDecision([c(2,{app:'editor',sampledAt:'new'}),c(2,{app:'editor'})],first.next);
 assert.equal(second.wake,false);assert.equal(second.notify,false);assert.equal(second.execute,false);assert.equal(first.wake,true);
 assert.equal(shadowDecision([c(3,{availability:'read-unavailable'})],first.next).wake,true);
 assert.equal(shadowDecision([c(4,{}, {assertion:'user'})],first.next).wake,true);
});
test('new archiver starting after the latest event sees an empty page rather than invalid cursor',async()=>{
 const f=fixture();const page=await f.core.research.batches({afterMinute:100});assert.deepEqual(page.entries,[]);assert.equal(page.nextCursor,100);assert.equal(page.throughMinute,100);assert.equal(page.hasMore,false);
 await assert.rejects(f.core.research.batches({afterMinute:100,throughMinute:99}),/终点/);
});
test('cached record_context adapter uses the same evidence checks and does not create an inferred activity',async()=>{
 const f=await researchFixture(),calls=await readForBatch(f),body=completion(f,calls);
 const result=await f.core.recordContext({id:body.resultId,kind:'bc.research.batch_result',assertion:'inferred',confidence:'unknown',basis:calls,body},'owner');
 assert.equal(result.recorded,true);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM notes').get().n,0);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 await assert.rejects(f.core.recordContext({id:'invalid',kind:'bc.research.batch_result',body:{...body,resultId:'invalid',readCallIds:['invented']}},'owner'),/不存在/);
});
test('later research completion preserves original legacy processed time and escapes unusual secret-bearing parameters',async()=>{
 const f=await researchFixture(),calls=await readForBatch(f);await f.core.acknowledgeBatch(f.batch.batchId,'owner');const original=f.time();f.advance(60000);
 const result=await f.core.research.complete(completion(f,calls),'owner');assert.equal(result.processedAt,original);assert.equal(result.recordedAt,f.time());
 assert.equal((await f.core.research.complete(completion(f,calls),'owner')).recordedAt,result.recordedAt);
 assert.deepEqual(safeArguments({basis:['Bearer "odd-secret" text']}),{basis:['[redacted] text']});
});

test('normal device heartbeat refresh can skip shadow wake, while changes and errors remain protected',()=>{
 const c=(id,value,extra={})=>({id,sourceKey:'mac_device:device.status',observation:{eventId:String(id),source:'device.status',assertion:'observed',value,...extra}});
 const first=shadowDecision([c(1,{availability:'online',collector:{build:'164'},sampledAt:'old'})]);
 const refresh=shadowDecision([c(2,{sampledAt:'new',collector:{build:'164'},availability:'online'})],first.next);
 assert.equal(first.wake,true);assert.equal(refresh.wake,false);assert.equal(refresh.version,2);
 assert.equal(refresh.notify,false);assert.equal(refresh.execute,false);assert.equal(refresh.sideEffects,false);
 assert.equal(shadowDecision([c(3,{availability:'online',collector:{build:'165'}})],first.next).wake,true);
 assert.equal(shadowDecision([c(4,{availability:'offline'})],first.next).wake,true);
 assert.equal(shadowDecision([c(5,{availability:'online',collector:{build:'164'}},{freshness:'stale'})],first.next).wake,true);
 assert.equal(shadowDecision([c(6,{availability:'online',collector:{build:'164'}},{assertion:'user'})],first.next).wake,true);
 // Unknown source statuses cannot borrow the device-only exception.
 assert.equal(shadowDecision([{...c(7,{availability:'online'}),sourceKey:'mac_device:health.status',observation:{source:'health.status',value:{availability:'online'}}}],first.next).wake,true);
});

test('legacy history pins one device snapshot and never creates shared timers',async()=>{
 const f=fixture(),d=await poolDevice(f);await publishPool(f,d,[]);
 const unsupported=await f.core.taskHistory({origin:'legacy',deviceId:d.id});assert.equal(unsupported.complete,false);assert.equal(unsupported.availability,'not_supported_by_device_snapshot');
 assert.equal((await f.core.taskHistory()).sessions.length,0);
 const make=(n,start=Date.parse('2026-10-05T08:00:00Z'))=>({id:'legacy:'+String(n).padStart(64,'0'),revision:'a'.repeat(64),values:{id:'legacy:'+String(n).padStart(64,'0'),origin:'swiftdata_execution_session',title:'identical original text',start,end:start+3600000,commandId:null,unknownField:{keep:true}}});
 const rows=[make(1),make(2),make(3,Date.parse('2026-10-04T08:00:00Z'))];f.advance(60000);await publishPool(f,d,[],{seq:20,eventPrefix:'legacy-original',executionSessions:rows});
 const range={origin:'legacy',deviceId:d.id,from:'2026-10-05T00:00:00Z',before:'2026-10-05T23:59:59Z',limit:1};
 const first=await f.core.taskHistory(range);assert.equal(first.sessions.length,1);assert.equal(first.hasMore,true);assert.equal(first.matchedRecordCount,2);
 f.advance(60000);await publishPool(f,d,[],{seq:40,eventPrefix:'legacy-new',executionSessions:[make(4)]});
 const second=await f.core.taskHistory({...range,cursor:first.nextCursor});assert.equal(second.sessions[0].id,rows[1].id);assert.equal(second.hasMore,false);assert.equal(second.sessions[0].values.unknownField.keep,true);assert.equal(second.pinnedSnapshot,true);
 assert.equal((await f.core.taskHistory(range)).sessions[0].id,make(4).id);
 await assert.rejects(f.core.taskHistory({...range,deviceId:'another',cursor:first.nextCursor}),/游标/);await assert.rejects(f.core.taskHistory({...range,deviceId:undefined}),/指定设备/);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,0);
});
test('legacy identity corruption and mixed filters fail visibly',async()=>{
 const f=fixture(),d=await poolDevice(f),id='legacy:'+'b'.repeat(64),r={id,revision:'a'.repeat(64),values:{id,origin:'swiftdata_execution_session',title:'original',start:100,end:null,commandId:null}};
 await publishPool(f,d,[],{executionSessions:[r,r]});await assert.rejects(f.core.taskHistory({origin:'legacy',deviceId:d.id}),/身份/);
 await assert.rejects(f.core.readPoolRecords({recordType:'execution',zone:'todo'}),/混用/);await assert.rejects(f.core.taskHistory({origin:'legacy',deviceId:d.id,from:'not-a-date'}),/时间/);
});
test('content expiry differs from sample recency; day-total corrections retain fractions and do not add snapshots',()=>{
 const base={source:'health.steps',observedAt:'2026-10-13T20:00:00Z',receivedAt:'2026-10-13T21:00:00Z',expiresAt:'2026-10-13T22:00:00Z',value:{count:1664.876,snapshot:true,additive:false}};
 const old=sourceView(base,'phone:health.steps','2026-10-13T21:01:00Z');assert.equal(old.freshness,'current');assert.equal(old.collectionRecency,'older_than_5_minutes');assert.equal(old.deliveryDelaySeconds,3600);assert.equal(old.observationAgeSeconds,3660);assert.equal(old.value.count,1664.876);
 const correction=sourceView({...base,value:{count:1209,snapshot:true,additive:false}},'phone:health.steps','2026-10-13T21:01:00Z');assert.equal(correction.value.count,1209);assert.equal(correction.value.additive,false);
 const none=sourceView({...base,value:{count:null,availability:'no-readable-samples-not-proof-of-no-steps'}},'phone:health.steps','2026-10-13T21:01:00Z');assert.equal(none.availability,'unknown');
});

test('diagnostic idle seconds alone refresh stored state without manufacturing activity changes',async()=>{
 const f=fixture(),d=await device(f);
 await f.core.ingest({observations:[obs(1,{idle:'over30min',inputIdleSeconds:2000,foregroundChanged:false,activityActor:'unknown'},f)]},d);
 f.advance(1000);await f.core.ingest({observations:[obs(2,{idle:'over30min',inputIdleSeconds:2001,foregroundChanged:false,activityActor:'unknown'},f)]},d);
 assert.equal((await f.core.readChanges()).changes.length,1);assert.equal((await f.core.readState()).sources[0].value.inputIdleSeconds,2001);
 f.advance(1000);await f.core.ingest({observations:[obs(3,{idle:'active',inputIdleSeconds:0,foregroundChanged:true,activityActor:'unknown'},f)]},d);
 assert.equal((await f.core.readChanges()).changes.length,2);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM observations').get().n,3);
});

test('lightweight state metadata retains collection age and delivery delay without returning source content',async()=>{
 const f=fixture(),d=await device(f);
 const o=obs(1,{app:'private fixture'},f);f.advance(3600000);await f.core.ingest({observations:[o]},d);
 const s=(await f.core.readState({includeValues:false})).sources[0];assert.equal(s.observationAgeSeconds,3600);assert.equal(s.deliveryDelaySeconds,3600);assert.equal(s.collectionRecency,'older_than_5_minutes');assert.equal('value' in s,false);assert.match(s.freshnessMeaning,/not_continuous/);
});

test('server-issued entry and page cursors read legacy history through an older cached tool schema',async()=>{
 const f=fixture(),d=await poolDevice(f),make=n=>{const id='legacy:'+String(n).padStart(64,'0');return {id,revision:'a'.repeat(64),values:{id,origin:'swiftdata_execution_session',title:'fixture',start:100,end:200,commandId:null}};};
 await publishPool(f,d,[],{executionSessions:[make(1),make(2)]});
 const entry=(await f.core.readState({includeValues:false})).sources.find(s=>s.source==='bc.pool').legacyTimingEntryCursor;
 const first=await f.core.taskHistory({cursor:entry,limit:1});assert.equal(first.origin,'legacy');assert.equal(first.sessions[0].id,make(1).id);assert.equal(first.hasMore,true);
 const second=await f.core.taskHistory({cursor:first.nextCursor,limit:1});assert.equal(second.origin,'legacy');assert.equal(second.sessions[0].id,make(2).id);assert.equal(second.hasMore,false);
 await assert.rejects(f.core.taskHistory({cursor:entry,deviceId:'other'}),/身份/);await assert.rejects(f.core.taskHistory({cursor:first.nextCursor,from:'2026-10-05T00:00:00Z'}),/范围/);
 await assert.rejects(f.core.taskHistory({cursor:'bc-legacy-entry-v1:broken'}),/游标/);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,0);
});

test('legacy entry supports existing Unicode device identifiers without breaking state reads',async()=>{
 const f=fixture(),d=await poolDevice(f,'设备一');await publishPool(f,d,[]);
 const entry=(await f.core.readState({includeValues:false})).sources.find(s=>s.source==='bc.pool').legacyTimingEntryCursor;
 const result=await f.core.taskHistory({cursor:entry});assert.equal(result.origin,'legacy');assert.equal(result.sourceDeviceId,d.id);assert.equal(result.availability,'not_supported_by_device_snapshot');
});

test('shared pomodoro duration is immutable and expiry never creates another command or ends work',async()=>{
 const f=fixture(),start={commandId:'pomo-fixture',action:'start',title:'ISOLATED POMO',mode:'pomodoro',focusMinutes:25,experiment:true,provenance:'user'};
 const s=await f.core.taskCommand(start);f.advance(20*60000);
 await f.core.taskCommand({commandId:'pomo-pause',action:'pause',sessionId:s.id,expectedRevision:1,provenance:'user'});
 f.advance(30*60000);assert.equal((await f.core.taskState()).sessions[0].elapsedMs,20*60000);
 await f.core.taskCommand({commandId:'pomo-resume',action:'resume',sessionId:s.id,expectedRevision:2,provenance:'user'});
 f.advance(6*60000);
 const current=(await f.reopen().taskState()).sessions[0];
 assert.equal(current.id,s.id);assert.equal(current.revision,3);assert.equal(current.status,'running');assert.equal(current.elapsedMs,26*60000);
 assert.equal(current.mode,'pomodoro');assert.equal(current.focusMinutes,25);assert.equal(current.experiment,true);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,3);
 assert.equal((await f.core.readState()).sessions.length,0);assert.equal((await f.core.readState({includeExperiments:true})).sessions.length,1);
 assert.equal((await f.core.taskHistory()).sessions.length,0);assert.equal((await f.core.readTaskCommands()).commands.length,0);
 const page=await f.core.readTaskCommands({includeExperiments:true,limit:1});assert.equal(page.hasMore,true);
 await assert.rejects(f.core.readTaskCommands({cursor:page.nextCursor,includeExperiments:false}),/游标/);
 const next=await f.core.readTaskCommands({cursor:page.nextCursor,includeExperiments:true,limit:1});assert.notEqual(next.commands[0].commandId,page.commands[0].commandId);
 const done=await f.core.taskCommand({commandId:'pomo-end',action:'finish',sessionId:s.id,expectedRevision:3,provenance:'user'});
 assert.equal(done.elapsedMs,26*60000);assert.equal(done.experiment,true);
 assert.equal((await f.core.taskHistory({includeExperiments:true})).sessions[0].id,s.id);
});
test('legacy sessions become light without rewriting old command receipts, invalid mode fields fail before saving',async()=>{
 const f=fixture();
 for(const fields of [{mode:'other'},{mode:'pomodoro'},{mode:'pomodoro',focusMinutes:1.5},{mode:'pomodoro',focusMinutes:241},{mode:'light',focusMinutes:25},{experiment:'true'}])await assert.rejects(f.core.taskCommand({commandId:'invalid',action:'start',title:'isolated',provenance:'user',...fields}));
 const s=await f.core.taskCommand({commandId:'old-style',action:'start',title:'isolated',provenance:'user'});
 assert.equal(s.mode,'light');assert.equal(s.focusMinutes,null);assert.equal(s.experiment,false);
 await assert.rejects(f.core.taskCommand({commandId:'mutate-mode',action:'pause',sessionId:s.id,expectedRevision:1,mode:'pomodoro',focusMinutes:25,provenance:'user'}),/仅在开始/);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,1);
 const oldReceipt=JSON.stringify({id:s.id,saved:true,revision:1});f.sqlite.prepare('UPDATE commands SET result=? WHERE id=?').run(oldReceipt,'old-style');
 assert.deepEqual((await f.core.readTaskCommands()).commands[0].result,JSON.parse(oldReceipt));
});

test('additive mode migration preserves existing session bytes and historical receipts',()=>{
 const sqlite=new DatabaseSync(':memory:');const files=readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort();
 for(const file of files.filter(f=>!f.startsWith('0008_')))sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 sqlite.prepare('INSERT INTO sessions(id,title,status,started_at,active_since,elapsed_ms,updated_at,revision,last_command_id,provenance) VALUES(?,?,?,?,?,?,?,?,?,?)').run('legacy','ISOLATED','paused','2026-10-05T10:00:00.000Z',null,90123,'2026-10-05T10:01:30.123Z',7,'legacy-command','user');
 const receipt='{"saved":true,"id":"legacy","unknownOldField":"preserved"}';
 sqlite.prepare('INSERT INTO commands(id,request_hash,session_id,result,created_at) VALUES(?,?,?,?,?)').run('legacy-command','hash','legacy',receipt,'2026-10-05T10:01:30.123Z');
 const before=sqlite.prepare('SELECT * FROM sessions').get();
 for(const file of files.filter(f=>f.startsWith('0008_')))sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 const after=sqlite.prepare('SELECT * FROM sessions').get();
 for(const [key,value] of Object.entries(before))assert.equal(after[key],value);
 assert.equal(after.mode,'light');assert.equal(after.focus_minutes,null);assert.equal(after.experiment,0);
 assert.equal(sqlite.prepare('SELECT result FROM commands').get().result,receipt);
});

test('two service instances racing pause and finish accept exactly one revision and retain the original winner receipt',async()=>{
 const f=fixture();const start=await f.core.taskCommand({commandId:'race-start',action:'start',title:'ISOLATED RACE',provenance:'user',experiment:true});f.advance(1000);
 const requests=['pause','finish'].map(action=>({commandId:'race-'+action,action,sessionId:start.id,expectedRevision:1,occurredAt:f.time(),provenance:'user'}));
 const outcomes=await Promise.allSettled(requests.map((r,i)=>(i?f.reopen():f.core).taskCommand(r,'device:fixture-'+i)));
 assert.equal(outcomes.filter(r=>r.status==='fulfilled').length,1);assert.equal(outcomes.filter(r=>r.status==='rejected'&&r.reason.status===409).length,1);
 const winner=outcomes.findIndex(r=>r.status==='fulfilled'),saved=outcomes[winner].value;
 assert.equal(saved.revision,2);assert.equal(saved.elapsedMs,1000);assert.equal(saved.experiment,true);
 assert.deepEqual(await f.reopen().taskCommand(requests[winner]),saved);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,2);
 assert.equal(f.sqlite.prepare('SELECT revision FROM sessions').get().revision,2);
});
