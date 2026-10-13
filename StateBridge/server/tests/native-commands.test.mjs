import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {createBridge} from '../lib/bridge.mjs';
import {nativeUUIDSchema} from '../lib/native-commands.mjs';
function fixture(){
 const sqlite=new DatabaseSync(':memory:');
 for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 let failRecord=false,beforeBatch=null;
 const prepare=sql=>{let args=[];return{bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return{results:sqlite.prepare(sql).all(...args)};},run(){if(failRecord&&sql.startsWith('INSERT OR IGNORE INTO research_log'))throw Error('disk full simulation');return sqlite.prepare(sql).run(...args);}};};
 const db={prepare,batch(ops){const hook=beforeBatch;beforeBatch=null;hook?.();sqlite.exec('BEGIN');try{const out=ops.map(o=>o.run());sqlite.exec('COMMIT');return out;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 let now=new Date('2026-10-13T10:00:00.000Z'),clockStep=0;const core=createBridge(db,{now:()=>{const at=now;now=new Date(now.getTime()+clockStep);return at;}});
 return{core,sqlite,time:()=>now.toISOString(),stepEveryRead(ms){clockStep=ms;},advance(ms){now=new Date(now.getTime()+ms);},failRecord(v){failRecord=v;},beforeBatch(fn){beforeBatch=fn;}};
}
const id=n=>`12345678-1234-4234-8234-${String(n).padStart(12,'0')}`;
async function setup(f){const token=await f.core.registerDevice({id:'iphone-test',label:'Fixture',scopes:['user.context']});const d=await f.core.authenticateDevice(token.token);await f.core.nativeCommands.setGrant({revision:1,capabilities:['item.create','item.update','alarm.schedule','alarm.cancel'],expiresAt:'2026-10-14T10:00:00.000Z'},d);return d;}
const request=(f,n=1)=>({version:1,commandId:id(n),deviceId:'iphone-test',kind:'item',action:'create',recordId:id(100+n),patch:{title:'ISOLATED FIXTURE'},occurredAt:f.time(),expiresAt:'2026-10-13T11:00:00.000Z',userRequest:'Isolated simulation, never a real user task'});
async function approved(f,v){const s=await f.core.nativeCommands.submit(v,'owner');assert.equal(s.value.state,'awaiting_confirmation');await f.core.nativeCommands.approve(s.approval,'owner');return s;}
test('agent-friendly names rejected before persistence; advertised UUID and distinct identity errors allow safe correction',async()=>{
 const f=fixture(),d=await setup(f);
 await f.core.nativeCommands.setGrant({revision:2,capabilities:['timer.start','journal.read'],expiresAt:'2026-10-14T10:00:00.000Z'},d);
 const timer={version:1,commandId:'dots-study-start-20261013',deviceId:d.id,kind:'timer',action:'start',title:'ISOLATED TIMER',userRequest:'Isolated explicit past-start fixture',occurredAt:f.time(),expiresAt:'2026-10-13T11:00:00.000Z',effectiveAt:'2026-10-13T09:00:00.000Z'};
 assert.equal(nativeUUIDSchema.format,'uuid');
 assert.equal(new RegExp(nativeUUIDSchema.pattern).test(timer.commandId),false);
 await assert.rejects(f.core.nativeCommands.submit(timer,'owner'),/commandId必须是UUID/);
 await assert.rejects(f.core.nativeCommands.readJournal({commandId:timer.commandId,deviceId:d.id},'owner'),/commandId必须是UUID/);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM native_requests').get().n,0);
 const corrected={...timer,commandId:id(910).toUpperCase()};
 assert.equal(new RegExp(nativeUUIDSchema.pattern).test(corrected.commandId),true);
 await assert.rejects(f.core.nativeCommands.submit({...corrected,version:2},'owner'),/version必须为1/);
 await assert.rejects(f.core.nativeCommands.submit({...corrected,deviceId:''},'owner'),/deviceId需要/);
 await assert.rejects(f.core.nativeCommands.submit({...corrected,userRequest:''},'owner'),/userRequest需要/);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM native_requests').get().n,0);
 const accepted=await f.core.nativeCommands.submit(corrected,'owner');
 assert.equal(accepted.value.state,'awaiting_confirmation');
 assert.equal(accepted.value.request.effectiveAt,timer.effectiveAt);
 assert.equal(accepted.value.approvedAt,null);
 assert.equal((await f.core.nativeCommands.pending({},d)).commands.length,0);
 const retry=await f.core.nativeCommands.submit(corrected,'owner');
 assert.equal(retry.value.commandId,accepted.value.commandId);
 assert.equal(retry.value.requestHash,accepted.value.requestHash);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM native_requests').get().n,1);
 await assert.rejects(f.core.nativeCommands.submit({...corrected,effectiveAt:'2026-10-13T08:00:00.000Z'},'owner'),/不可改变/);
});
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
test('journal read requires separate grant, queues without mutation confirmation and retains exact requested page',async()=>{
 const f=fixture(),d=await setup(f),v={commandId:id(600),deviceId:d.id,query:{text:'fixture',limit:1}};
 await assert.rejects(f.core.nativeCommands.readJournal(v,'owner'),/权限未启用/);
 await f.core.nativeCommands.setGrant({revision:2,capabilities:['journal.read'],expiresAt:'2026-10-14T10:00:00.000Z'},d);
 const s=await f.core.nativeCommands.readJournal(v,'owner');assert.equal(s.state,'queued');assert.equal(s.approvedAt,null);assert.equal(s.operationEffect,'read_only');
 f.advance(1000);const repeated=await f.core.nativeCommands.readJournal(v,'owner');assert.equal(repeated.requestHash,s.requestHash);assert.equal(repeated.acceptedAt,s.acceptedAt);
 await assert.rejects(f.core.nativeCommands.readJournal({...v,query:{text:'different'}},'owner'),/不可改变/);
 await assert.rejects(f.core.nativeCommands.readJournal(v,'other-owner'),/不存在/);
 const claim={commandId:v.commandId,requestHash:s.requestHash,attemptId:id(601)};
 await f.core.nativeCommands.claim(claim,d);
 const page={authority:'swiftdata',readAt:f.time(),records:[{id:id(602),revision:'full-hash',values:{body:'isolated diary text'}}],hasMore:true,complete:false,nextCursor:'fixture-page-2',coverage:{photoBinaries:'not_requested_or_retrieved'}};
 const r=await f.core.nativeCommands.receipt({...claim,outcome:'applied',receipt:page},d);assert.equal(r.deviceApplication,'device_reported_read');assert.deepEqual(r.result,page);
 const evidence=await f.core.research.evidence({nativeCommandIds:[v.commandId]});assert.deepEqual(evidence.nativeCommands[0].result,page);
 const denied={...s.request,commandId:id(603),action:'create',recordId:id(604),entryDate:f.time(),patch:{body:'must not write'}};delete denied.query;await assert.rejects(f.core.nativeCommands.submit(denied,'owner'),/权限未启用/);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM native_requests WHERE permission<>'journal.read' AND command_id=?").get(id(603)).n,0);
});
test('journal text create/update keep human confirmation and reject delete/photo/date widening',async()=>{
 const f=fixture(),d=await setup(f);await f.core.nativeCommands.setGrant({revision:2,capabilities:['journal.create','journal.update'],expiresAt:'2026-10-14T10:00:00.000Z'},d);
 const v={...request(f,700),kind:'journal',action:'create',entryDate:f.time(),patch:{body:'fixture subjective text',mood:null,tags:['fixture']}};
 const s=await approved(f,v);const claim={commandId:v.commandId,requestHash:s.value.requestHash,attemptId:id(701)};assert.equal((await f.core.nativeCommands.claim(claim,d)).state,'dispatching');
 const update={...v,commandId:id(702),action:'update',expectedRevision:'actual revision'};delete update.entryDate;assert.equal((await f.core.nativeCommands.submit(update,'owner')).value.state,'awaiting_confirmation');
 await assert.rejects(f.core.nativeCommands.submit({...v,commandId:id(703),action:'delete'},'owner'),/操作无效/);
 await assert.rejects(f.core.nativeCommands.submit({...v,commandId:id(704),patch:{body:'x',photoRefs:[]}},'owner'),/字段/);
 await assert.rejects(f.core.nativeCommands.submit({...update,commandId:id(705),entryDate:f.time()},'owner'),/原始版本/);
 await assert.rejects(f.core.nativeCommands.submit({...v,commandId:id(706),patch:{body:'中'.repeat(6000)}},'owner'),/文字/);
 await assert.rejects(f.core.nativeCommands.readJournal({commandId:id(707),deviceId:d.id},'owner'),/权限未启用/);
});
test('journal read range validation and revoked queued read cannot leak through later execution',async()=>{
 const f=fixture(),d=await setup(f);await f.core.nativeCommands.setGrant({revision:2,capabilities:['journal.read'],expiresAt:'2026-10-14T10:00:00.000Z'},d);
 await assert.rejects(f.core.nativeCommands.readJournal({commandId:id(800),deviceId:d.id,query:{limit:0}},'owner'),/范围/);
 await assert.rejects(f.core.nativeCommands.readJournal({commandId:id(800),deviceId:d.id,query:{start:f.time(),end:f.time()}},'owner'),/范围/);
 const s=await f.core.nativeCommands.readJournal({commandId:id(801),deviceId:d.id,query:{start:'2026-10-12T10:00:00.000Z',end:f.time()}},'owner');
 await f.core.nativeCommands.setGrant({revision:3,capabilities:[],expiresAt:'2026-10-14T10:00:00.000Z'},d);
 assert.equal((await f.core.nativeCommands.status({commandId:id(801)},'owner')).state,'revoked');
 await assert.rejects(f.core.nativeCommands.claim({commandId:id(801),requestHash:s.requestHash,attemptId:id(802)},d),/权限未启用/);
 assert.equal(f.sqlite.prepare('SELECT result FROM native_requests WHERE command_id=?').get(id(801)).result,null);
});

test('concurrent identical journal reads keep one original command despite independently generated timestamps',async()=>{
 const f=fixture(),d=await setup(f);await f.core.nativeCommands.setGrant({revision:2,capabilities:['journal.read'],expiresAt:'2026-10-14T10:00:00.000Z'},d);f.stepEveryRead(1);
 const v={commandId:id(900),deviceId:d.id,query:{limit:1}};
 const [first,second]=await Promise.all([f.core.nativeCommands.readJournal(v,'owner'),f.core.nativeCommands.readJournal(v,'owner')]);
 assert.equal(first.requestHash,second.requestHash);assert.equal(first.acceptedAt,second.acceptedAt);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_requests WHERE command_id=?').get(v.commandId).n,1);
 await assert.rejects(f.core.nativeCommands.readJournal({...v,query:{limit:2}},'owner'),/不可改变/);
});

const timerRequest=(f,n,action='start',fields={})=>({version:1,commandId:id(n),deviceId:'iphone-test',kind:'timer',action,...(action==='start'?{title:'ISOLATED TIMER FIXTURE'}:{}),...fields,occurredAt:f.time(),expiresAt:'2026-10-13T11:00:00.000Z',userRequest:'Isolated timer simulation; never actual user intent'});
async function timerGrant(f,d){await f.core.nativeCommands.setGrant({revision:2,capabilities:['timer.start','timer.pause','timer.resume','timer.finish'],expiresAt:'2026-10-14T10:00:00.000Z'},d);}
async function timerExecute(f,d,v,attempt){const s=await approved(f,v),identity={commandId:v.commandId,requestHash:s.value.requestHash,attemptId:id(attempt)};await f.core.nativeCommands.claim(identity,d);return {identity,result:await f.core.nativeCommands.executeTimer(identity,d)};}
test('timer uses independent grant, human approval, fixed device and confirmation timestamp',async()=>{
 const f=fixture(),d=await setup(f),v=timerRequest(f,1000);
 await assert.rejects(f.core.nativeCommands.submit(v,'owner'),/权限未启用/);await timerGrant(f,d);
 const s=await f.core.nativeCommands.submit(v,'owner'),identity={commandId:v.commandId,requestHash:s.value.requestHash,attemptId:id(1001)};
 assert.equal(s.value.state,'awaiting_confirmation');assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 await assert.rejects(f.core.nativeCommands.executeTimer(identity,d),/已确认/);
 await assert.rejects(f.core.nativeCommands.approve({...s.approval,token:'model claims yes'},'owner'),/确认按钮/);
 f.advance(30000);const confirmed=await f.core.nativeCommands.approve(s.approval,'owner');
 await f.core.nativeCommands.claim(identity,d);f.advance(300000);
 const value=await f.core.nativeCommands.executeTimer(identity,d);assert.equal(value.startedAt,confirmed.approvedAt);assert.equal(value.revision,1);assert.equal(value.saved,true);
 assert.equal(value.origin,'confirmed-device:iphone-test');
 await assert.rejects(f.core.nativeCommands.executeTimer(identity,{id:'different'}),/权限|不存在/);
 await assert.rejects(f.core.nativeCommands.submit({...v,provenance:'user',commandId:id(1002)},'owner'),/字段/);
});
test('confirmed timer reuses exactly one cloud command after lost response and handles pause resume finish',async()=>{
 const f=fixture(),d=await setup(f);await timerGrant(f,d);
 const start=await timerExecute(f,d,timerRequest(f,1100),1101); // response can be lost after this transaction
 f.advance(30000);assert.deepEqual(await f.core.nativeCommands.executeTimer(start.identity,d),start.result);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,1);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,1);
 const pause=await timerExecute(f,d,timerRequest(f,1102,'pause',{sessionId:start.result.id,expectedRevision:1}),1103);
 assert.equal(pause.result.status,'paused');assert.equal(pause.result.elapsedMs,30000);assert.equal(pause.result.revision,2);
 f.advance(20000);const resume=await timerExecute(f,d,timerRequest(f,1104,'resume',{sessionId:start.result.id,expectedRevision:2}),1105);
 assert.equal(resume.result.elapsedMs,30000);f.advance(10000);
 const finish=await timerExecute(f,d,timerRequest(f,1106,'finish',{sessionId:start.result.id,expectedRevision:3}),1107);
 assert.equal(finish.result.status,'finished');assert.equal(finish.result.elapsedMs,40000);assert.equal(finish.result.revision,4);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,4);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM native_requests WHERE permission LIKE 'item.%'").get().n,0); // no item command is created
 await assert.rejects(f.core.nativeCommands.submit({...timerRequest(f,1100),title:'different same id'},'owner'),/不可改变/);
});
test('timer conflict cannot overwrite a newer action from the other device',async()=>{
 const f=fixture(),d=await setup(f);await timerGrant(f,d);const first=await timerExecute(f,d,timerRequest(f,1200),1201);
 const s=await approved(f,timerRequest(f,1202,'pause',{sessionId:first.result.id,expectedRevision:1}));
 f.advance(1000);await f.core.taskCommand({commandId:'fixture-other-device',action:'pause',sessionId:first.result.id,expectedRevision:1,occurredAt:f.time(),provenance:'user'},'device:other-fixture');
 const identity={commandId:id(1202),requestHash:s.value.requestHash,attemptId:id(1203)};await f.core.nativeCommands.claim(identity,d);
 await assert.rejects(f.core.nativeCommands.executeTimer(identity,d),/状态已变/);
 const current=(await f.core.taskState(d)).sessions[0];assert.equal(current.revision,2);assert.equal(current.status,'paused');assert.equal(current.lastCommandId,'fixture-other-device');
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands WHERE id=?').get(id(1202)).n,0);
});
test('timer authorization is checked inside mutation transaction after grant reads',async()=>{
 for(const revoke of ['grant','device']){
  const f=fixture(),d=await setup(f);await timerGrant(f,d);const v=timerRequest(f,1300),s=await approved(f,v),identity={commandId:v.commandId,requestHash:s.value.requestHash,attemptId:id(1301)};await f.core.nativeCommands.claim(identity,d);
  f.beforeBatch(()=>{if(revoke==='grant')f.sqlite.prepare("UPDATE native_grants SET revision=revision+1,body=? WHERE device_id=?").run(JSON.stringify({capabilities:[]}),d.id);else f.sqlite.prepare('UPDATE devices SET revoked_at=? WHERE id=?').run(f.time(),d.id);});
  await assert.rejects(f.core.nativeCommands.executeTimer(identity,d),/并发冲突/);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM commands').get().n,0);
  assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM changes WHERE source_key='bc:tasks'").get().n,0);
 }
});
test('timer validates action-specific version fields and cannot widen to unrelated native writes',async()=>{
 const f=fixture(),d=await setup(f);await timerGrant(f,d);
 for(const bad of [{expectedRevision:1},{sessionId:'some-old-session'},{patch:{status:'done'}},{entryDate:f.time()},{alarmId:id(1400)}])await assert.rejects(f.core.nativeCommands.submit(timerRequest(f,1401,'start',bad),'owner'));
 await assert.rejects(f.core.nativeCommands.submit(timerRequest(f,1402,'pause',{sessionId:'task_fixture',expectedRevision:'1'}),'owner'),/整数版本/);
 await assert.rejects(f.core.nativeCommands.submit(request(f,1403),'owner'),/权限未启用/);
});

test('explicit past timer time is displayed and confirmed, not replaced by model inferred history',async()=>{
 const f=fixture(),d=await setup(f);await timerGrant(f,d);
 const past='2026-10-13T09:50:00.000Z',v=timerRequest(f,1500,'start',{effectiveAt:past});
 const submitted=await f.core.nativeCommands.submit(v,'owner');assert.equal(submitted.value.request.effectiveAt,past);assert.equal(submitted.value.state,'awaiting_confirmation');
 await f.core.nativeCommands.approve(submitted.approval,'owner');const identity={commandId:v.commandId,requestHash:submitted.value.requestHash,attemptId:id(1501)};await f.core.nativeCommands.claim(identity,d);
 assert.equal((await f.core.nativeCommands.executeTimer(identity,d)).startedAt,past);
 await assert.rejects(f.core.nativeCommands.submit(timerRequest(f,1502,'start',{effectiveAt:'2026-10-13T10:01:00.000Z'}),'owner'),/未来/);
});
