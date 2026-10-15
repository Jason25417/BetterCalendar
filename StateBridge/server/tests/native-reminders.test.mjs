import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {createBridge} from '../lib/bridge.mjs';
import {confirmationPresentation} from '../lib/confirmation-presentation.mjs';
import {nativeFormParameters} from '../lib/native-form-confirmation.mjs';
const id=n=>`eeaabbee-abcd-4abc-8abc-${String(n).padStart(12,'0')}`,rev=n=>String(n).repeat(64);
async function fixture(t,caps=['reminder.read','reminder.schedule','reminder.update','reminder.cancel']){
 const sqlite=new DatabaseSync(':memory:');t.after(()=>sqlite.close());
 for(const f of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(readFileSync(new URL('../drizzle/'+f,import.meta.url),'utf8'));
 const prepare=sql=>{let args=[];return{bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return{results:sqlite.prepare(sql).all(...args)};},run(){return sqlite.prepare(sql).run(...args);}};};
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const out=ops.map(o=>o.run());sqlite.exec('COMMIT');return out;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 let now=new Date('2026-10-15T17:00:00.000Z');
 const core=createBridge(db,{now:()=>new Date(now),fetcher:()=>{throw Error('network forbidden');}}),token=await core.registerDevice({id:'fixture-device',label:'Isolated Mac',scopes:['user.context']}),d=await core.authenticateDevice(token.token);
 await core.nativeCommands.setGrant({revision:1,capabilities:caps,expiresAt:'2026-10-16T17:00:00.000Z'},d);
 const request=n=>({version:1,commandId:id(n),deviceId:d.id,kind:'reminder',action:'schedule',reminderId:id(100),title:'ISOLATED reminder',body:'Synthetic fixture, never real life',fireAt:'2026-10-15T18:00:00.000Z',sound:false,experiment:true,occurredAt:now.toISOString(),userRequest:'Isolated ordinary-reminder protocol fixture'});
 const submit=v=>core.nativeCommands.submit(v,'fixture-owner',{formOrigin:'submit_native_command'});
 async function apply(p,record){
  if(p.approval)await core.nativeCommands.approve(p.approval,'fixture-owner');
  const identity={commandId:p.value.commandId,requestHash:p.value.requestHash,attemptId:crypto.randomUUID()};
  await core.nativeCommands.claim(identity,d);
  const receipt={record,checkedAt:now.toISOString(),channel:'ordinary_notification',stage:record.cancelled?'system_absence_verified':'system_schedule_verified',userSeen:'unknown',guaranteedWake:false};
  return core.nativeCommands.receipt({...identity,outcome:'applied',receipt},d);
 }
 const record=(v,r=rev(1))=>({reminderId:v.reminderId,revision:r,title:v.title,body:v.body,fireAt:v.fireAt,sound:v.sound,experiment:v.experiment,cancelled:false});
 return {core,sqlite,d,request,submit,apply,record,advance(ms){now=new Date(now.getTime()+ms);}};
}
test('ordinary reminders have independent read and mutation grants and never inherit item/alarm authority',async t=>{
 const f=await fixture(t,['item.create','alarm.schedule']);
 await assert.rejects(f.submit(f.request(1)),e=>e.status===403);
 await assert.rejects(f.core.nativeCommands.readReminders({commandId:id(2),deviceId:f.d.id},'fixture-owner'),e=>e.status===403);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_requests').get().n,0);
});
test('all mutation values are explicit and unrelated kinds cannot smuggle reminder fields',async t=>{
 const f=await fixture(t);let n=10;
 for(const field of ['title','body','fireAt','sound','experiment','reminderId']){const v=f.request(n++);delete v[field];await assert.rejects(f.submit(v));}
 await assert.rejects(f.submit({...f.request(n++),expectedRevision:rev(1)}));
 await assert.rejects(f.submit({...f.request(n++),kind:'alarm'}));
 await assert.rejects(f.submit({...f.request(n++),kind:'timer',action:'start'}));
 await assert.rejects(f.submit({...f.request(n++),action:'cancel',expectedRevision:rev(1)}));
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_requests').get().n,0);
});
test('read is queued under read-only grant without approval, bound to same device/query and actual read receipt',async t=>{
 const f=await fixture(t,['reminder.read']),input={commandId:id(30),deviceId:f.d.id,query:{reminderId:id(100),includeCancelled:true}};
 const r=await f.core.nativeCommands.readReminders(input,'fixture-owner');assert.equal(r.state,'queued');assert.equal(r.approvedAt,null);assert.equal(r.operationEffect,'read_only');
 assert.equal((await f.core.nativeCommands.approvalList({},f.d)).commands.length,0);assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,1);
 assert.equal((await f.core.nativeCommands.readReminders(input,'fixture-owner')).requestHash,r.requestHash);
 await assert.rejects(f.core.nativeCommands.readReminders({...input,query:{}},'fixture-owner'),e=>e.status===409);
 const identity={commandId:r.commandId,requestHash:r.requestHash,attemptId:id(31)};
 await f.core.nativeCommands.claim(identity,f.d);
 const result=await f.core.nativeCommands.receipt({...identity,outcome:'applied',receipt:{records:[],complete:true,hasMore:false,nextCursor:null,operationEffect:'read_only'}},f.d);
 assert.equal(result.deviceApplication,'device_reported_read');assert.equal(result.userSeen,'unknown');
});
test('creation, update and cancellation bind same reminder with latest real device before-values',async t=>{
 const f=await fixture(t),v=f.request(40),p=await f.submit(v);
 assert.equal(p.value.state,'awaiting_confirmation');assert.equal(p.value.approvedAt,null);
 await assert.rejects(f.core.nativeCommands.claim({commandId:v.commandId,requestHash:p.value.requestHash,attemptId:id(41)},f.d));
 const first=await f.apply(p,f.record(v));assert.equal(first.state,'applied');f.advance(1);
 const update={...f.request(42),action:'update',title:'ISOLATED replacement',expectedRevision:rev(1)};
 const u=await f.submit(update),display=await confirmationPresentation(f.core,u.value);
 assert.equal(display.before.title,v.title);assert.equal(display.before.sound,false);
 const form=nativeFormParameters(u.value,display),description=form.requestedSchema.properties.confirm.description;
 assert.ok(description.includes(v.title)&&description.includes(update.title)&&description.includes(v.body)&&description.includes(v.fireAt));
 assert.ok(description.includes('声音')&&description.includes('合成测试')&&description.includes('普通系统通知'));
 await f.apply(u,f.record(update,rev(2)));f.advance(1);
 const cancel={version:1,commandId:id(43),deviceId:f.d.id,kind:'reminder',action:'cancel',reminderId:v.reminderId,expectedRevision:rev(2),occurredAt:v.occurredAt,userRequest:'Isolated cancellation'};
 const c=await f.submit(cancel),before=await confirmationPresentation(f.core,c.value);
 assert.equal(before.before.title,update.title);
 const cancelled={...f.record(update,rev(3)),cancelled:true};await f.apply(c,cancelled);
 assert.equal((await f.submit(cancel)).value.state,'applied');
 await assert.rejects(f.core.nativeCommands.reminderSnapshot(f.d.id,v.reminderId,rev(2)),e=>e.status===409);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_approval_decision'").get().n,3);
});
test('missing before, newest revision conflict and elapsed fire time never create usable approval',async t=>{
 const f=await fixture(t),v={...f.request(50),action:'update',expectedRevision:rev(1)},p=await f.submit(v);
 await assert.rejects(confirmationPresentation(f.core,p.value),e=>e.status===409);
 const created=f.request(51);await f.apply(await f.submit(created),f.record(created,rev(2)));
 await assert.rejects(confirmationPresentation(f.core,p.value),e=>e.status===409);
 const future=await f.submit(f.request(52));f.advance(3600001);
 await assert.rejects(f.core.nativeCommands.approve(future.approval,'fixture-owner'),e=>e.status===409);
 assert.equal((await f.core.nativeCommands.status({commandId:future.value.commandId},'fixture-owner')).state,'awaiting_confirmation');
});
test('late unknown read is not an empty catalog and invalid query cannot become a mutation',async t=>{
 const f=await fixture(t);
 for(const query of [{limit:21},{reminderId:'not-uuid'},{includeCancelled:'yes'},{cursor:'a'.repeat(2001)},{fireAt:'now'}])await assert.rejects(f.core.nativeCommands.readReminders({commandId:crypto.randomUUID(),deviceId:f.d.id,query},'fixture-owner'));
 const p=await f.core.nativeCommands.readReminders({commandId:id(60),deviceId:f.d.id,query:{}},'fixture-owner');
 assert.equal(p.state,'queued');assert.equal(p.result,null);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM native_requests WHERE approved_at IS NOT NULL").get().n,0);
});
test('read bypass never bypasses a revoked grant or permits a read-only caller to schedule',async t=>{
 const f=await fixture(t,['reminder.read']);
 const r=await f.core.nativeCommands.readReminders({commandId:id(70),deviceId:f.d.id,query:{}},'fixture-owner');
 await assert.rejects(f.submit(f.request(71)),e=>e.status===403);
 await f.core.nativeCommands.setGrant({revision:2,capabilities:[],expiresAt:'2026-10-16T17:00:00.000Z'},f.d);
 await assert.rejects(f.core.nativeCommands.claim({commandId:r.commandId,requestHash:r.requestHash,attemptId:id(72)},f.d),e=>e.status===403);
 assert.equal((await f.core.nativeCommands.status({commandId:r.commandId},'fixture-owner')).state,'revoked');
 assert.equal(f.sqlite.prepare('SELECT result FROM native_requests').get().result,null);
});
test('late stale read cannot hide a newer applied reminder revision in confirmation',async t=>{
 const f=await fixture(t),created=f.request(80);await f.apply(await f.submit(created),f.record(created));f.advance(1);
 const read=await f.core.nativeCommands.readReminders({commandId:id(81),deviceId:f.d.id,query:{reminderId:created.reminderId,includeCancelled:true}},'fixture-owner');
 const identity={commandId:read.commandId,requestHash:read.requestHash,attemptId:id(82)};await f.core.nativeCommands.claim(identity,f.d);
 f.advance(1);const updated={...f.request(83),action:'update',expectedRevision:rev(1),title:'Newer version'};await f.apply(await f.submit(updated),f.record(updated,rev(2)));f.advance(1);
 await f.core.nativeCommands.receipt({...identity,outcome:'applied',receipt:{records:[f.record(created)],readAt:'2026-10-15T17:00:00.001Z',complete:true,hasMore:false}},f.d);
 await assert.rejects(f.core.nativeCommands.reminderSnapshot(f.d.id,created.reminderId,rev(1)),e=>e.status===409);
 assert.equal((await f.core.nativeCommands.reminderSnapshot(f.d.id,created.reminderId,rev(2))).before.title,'Newer version');
});
