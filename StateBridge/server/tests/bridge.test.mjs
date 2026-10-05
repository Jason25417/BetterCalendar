import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { createBridge, signWebhook, validateCallback } from '../lib/bridge.mjs';
function fixture(){
 const sqlite=new DatabaseSync(':memory:');for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort()) sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 function prepare(sql){let args=[];return {bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return {results:sqlite.prepare(sql).all(...args)};},run(){return sqlite.prepare(sql).run(...args);}};}
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const r=ops.map(o=>o.run());sqlite.exec('COMMIT');return r;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 let clock=new Date('2026-10-05T12:00:00Z'),posts=[],fail=false;
 const fetcher=async(url,opts)=>{if(url.includes('dns-query'))return Response.json({Status:0,Answer:[{type:1,data:'104.18.1.1'}]});posts.push({url,...opts});if(fail)return new Response('',{status:503});let data=JSON.parse(opts.body);return Response.json(data.type==='verification'?{challenge:data.challenge}:{});};
 const core=createBridge(db,{now:()=>clock,fetcher});
 return {core,sqlite,posts,advance(ms){clock=new Date(clock.getTime()+ms);},setFail(v){fail=v;},time(){return clock.toISOString();}};
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
