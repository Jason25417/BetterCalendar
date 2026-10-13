import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {createBridge} from '../lib/bridge.mjs';
function fixture(){
 const sqlite=new DatabaseSync(':memory:');
 for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 let failRecord=false;
 const prepare=sql=>{let args=[];return{bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return{results:sqlite.prepare(sql).all(...args)};},run(){if(failRecord&&sql.startsWith('INSERT OR IGNORE INTO research_log'))throw Error('disk full simulation');return sqlite.prepare(sql).run(...args);}};};
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const out=ops.map(o=>o.run());sqlite.exec('COMMIT');return out;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 let now=new Date('2026-10-13T10:00:00.000Z');const core=createBridge(db,{now:()=>now});
 return{core,sqlite,time:()=>now.toISOString(),advance(ms){now=new Date(now.getTime()+ms);},failRecord(v){failRecord=v;}};
}
const id=n=>`12345678-1234-4234-8234-${String(n).padStart(12,'0')}`;
async function setup(f){const token=await f.core.registerDevice({id:'iphone-test',label:'Fixture',scopes:['user.context']});const d=await f.core.authenticateDevice(token.token);await f.core.nativeCommands.setGrant({revision:1,capabilities:['item.create','item.update','alarm.schedule','alarm.cancel'],expiresAt:'2026-10-14T10:00:00.000Z'},d);return d;}
const request=(f,n=1)=>({version:1,commandId:id(n),deviceId:'iphone-test',kind:'item',action:'create',recordId:id(100+n),patch:{title:'ISOLATED FIXTURE'},occurredAt:f.time(),expiresAt:'2026-10-13T11:00:00.000Z',userRequest:'Isolated simulation, never a real user task'});
async function approved(f,v){const s=await f.core.nativeCommands.submit(v,'owner');assert.equal(s.value.state,'awaiting_confirmation');await f.core.nativeCommands.approve(s.approval,'owner');return s;}
test('no model assertion can authorize; approval bound to owner and immutable payload',async()=>{
 const f=fixture(),d=await setup(f),v=request(f);await assert.rejects(f.core.nativeCommands.submit({...v,userConfirmed:true},'owner'),/字段/);
 const s=await f.core.nativeCommands.submit(v,'owner');assert.ok(s.approval.token);assert.equal(s.value.approvedAt,null);assert.equal(JSON.stringify(s.value).includes(s.approval.token),false);
 await assert.rejects(f.core.nativeCommands.approve({...s.approval,token:'model says approved'},'owner'),/确认按钮/);
 await assert.rejects(f.core.nativeCommands.approve(s.approval,'other-owner'),/不存在/);
 await assert.rejects(f.core.nativeCommands.approve({...s.approval,requestHash:'different'},'owner'),/确认按钮/);
 await assert.rejects(f.core.nativeCommands.claim({commandId:v.commandId,requestHash:s.value.requestHash,attemptId:id(400)},d),/未由用户/);
 assert.equal((await f.core.nativeCommands.pending({},d)).commands.length,0);
 await f.core.nativeCommands.approve(s.approval,'owner');assert.equal((await f.core.nativeCommands.pending({},d)).commands.length,1);
 await assert.rejects(f.core.nativeCommands.submit({...v,patch:{title:'different'}},'owner'),/不可改变/);
});
test('single device and stable execution identity, lost claim/receipt response, restart',async()=>{
 const f=fixture(),d=await setup(f),v=request(f),s=await approved(f,v),claim={commandId:v.commandId,requestHash:s.value.requestHash,attemptId:id(400)};
 const otherToken=await f.core.registerDevice({id:'other',label:'Other',scopes:['user.context']});const other=await f.core.authenticateDevice(otherToken.token);
 await assert.rejects(f.core.nativeCommands.claim(claim,other),/不匹配/);
 assert.equal((await f.core.nativeCommands.claim(claim,d)).state,'dispatching');
 assert.equal((await f.core.nativeCommands.claim(claim,d)).attemptId,claim.attemptId);
 await assert.rejects(f.core.nativeCommands.claim({...claim,attemptId:id(401)},d),/已有执行/);
 const r={...claim,outcome:'applied',receipt:{saved:true,authority:'swiftdata',persistedRevision:'actual-device-version',syncOtherDevices:'unknown'}};
 await f.core.nativeCommands.receipt(r,d);const retry=await f.core.nativeCommands.receipt(r,d);assert.equal(retry.state,'applied');assert.equal(retry.userSeen,'unknown');
 const restarted=createBridge({prepare:sql=>{let args=[];return{bind(...a){args=a;return this;},first(){return f.sqlite.prepare(sql).get(...args)??null;}};}});
 assert.equal((await restarted.nativeCommands.status({commandId:v.commandId},'owner')).result.persistedRevision,'actual-device-version');
 await assert.rejects(f.core.nativeCommands.receipt({...r,receipt:{saved:true,persistedRevision:'fake correction'}},d),/不可覆盖/);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_result'").get().n,1);
 const e=await f.core.research.evidence({nativeCommandIds:[v.commandId]});assert.equal(e.nativeCommands[0].body.userRequest,v.userRequest);assert.equal(JSON.stringify(e).includes(s.approval.token),false);assert.equal('approval_hash' in e.nativeCommands[0],false);
});
test('revocation/expiry forbid new execution; in-flight receipt preserves truth without new grant',async()=>{
 const f=fixture(),d=await setup(f),s=await approved(f,request(f)),claim={commandId:id(1),requestHash:s.value.requestHash,attemptId:id(400)};
 await f.core.nativeCommands.claim(claim,d);
 await f.core.nativeCommands.setGrant({revision:2,capabilities:[],expiresAt:'2026-10-14T10:00:00.000Z'},d);
 await assert.rejects(f.core.nativeCommands.claim(claim,d),/权限未启用/);
 await f.core.nativeCommands.receipt({...claim,outcome:'unknown',receipt:{reason:'revoked before local write'}},d);
 assert.equal((await f.core.nativeCommands.status({commandId:id(1)},'owner')).state,'unknown');
 const g={revision:3,capabilities:['item.create'],expiresAt:'2026-10-14T10:00:00.000Z'};await f.core.nativeCommands.setGrant(g,d);await f.core.nativeCommands.setGrant(g,d);
 await assert.rejects(f.core.nativeCommands.setGrant({...g,capabilities:[]},d),/不可复用/);
 const queued=await approved(f,request(f,2));f.advance(3600001);assert.equal((await f.core.nativeCommands.status({commandId:id(2)},'owner')).state,'expired');
 await assert.rejects(f.core.nativeCommands.claim({commandId:id(2),requestHash:queued.value.requestHash,attemptId:id(401)},d),/过期/);
 assert.equal((await f.core.nativeCommands.submit(request({...f,time:()=> '2026-10-13T10:00:00.000Z'},2),'owner')).value.state,'expired');
});
test('pagination, entire result persistence transaction, request validation and missing permissions',async()=>{
 const f=fixture(),d=await setup(f);for(let n=1;n<=3;n++)await approved(f,request(f,n));
 const page=await f.core.nativeCommands.pending({limit:2},d);assert.equal(page.hasMore,true);assert.equal(page.commands.length,2);
 const last=await f.core.nativeCommands.pending({limit:2,after:page.nextCursor,through:page.through},d);assert.equal(last.hasMore,false);assert.equal(last.commands.length,1);
 const s=await f.core.nativeCommands.status({commandId:id(1)},'owner'),claim={commandId:id(1),requestHash:s.requestHash,attemptId:id(400)};await f.core.nativeCommands.claim(claim,d);
 const r={...claim,outcome:'applied',receipt:{saved:true}};f.failRecord(true);await assert.rejects(f.core.nativeCommands.receipt(r,d),/disk full/);
 assert.equal((await f.core.nativeCommands.status({commandId:id(1)},'owner')).state,'dispatching');f.failRecord(false);assert.equal((await f.core.nativeCommands.receipt(r,d)).state,'applied');
 await assert.rejects(f.core.nativeCommands.submit({...request(f,4),patch:{title:'x',zone:'longterm'}},'owner'),/字段/);
 await assert.rejects(f.core.nativeCommands.submit({...request(f,5),action:'delete',patch:{}},'owner'),/原始版本/);
 const clock=await f.core.registerDevice({id:'clock',label:'Clock',scopes:['clock.tick']});const c=await f.core.authenticateDevice(clock.token);await assert.rejects(f.core.nativeCommands.setGrant({revision:1,capabilities:['item.create'],expiresAt:'2026-10-14T10:00:00.000Z'},c),/权限/);
});
