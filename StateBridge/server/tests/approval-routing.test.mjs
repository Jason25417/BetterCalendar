import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {createBridge} from '../lib/bridge.mjs';
const id=n=>`abcdabcd-abcd-4abc-8abc-${String(n).padStart(12,'0')}`;
async function fixture(t){
 const sqlite=new DatabaseSync(':memory:');t.after(()=>sqlite.close());
 for(const f of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(readFileSync(new URL('../drizzle/'+f,import.meta.url),'utf8'));
 let now=new Date('2026-10-15T14:00:00.000Z'),beforeBatch=null,failAudit=false;
 const prepare=sql=>{let args=[];return{bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return{results:sqlite.prepare(sql).all(...args)};},run(){if(failAudit&&sql.startsWith('INSERT INTO research_log'))throw Error('isolated durable audit failure');return sqlite.prepare(sql).run(...args);}};};
 const db={prepare,batch(ops){const hook=beforeBatch;beforeBatch=null;hook?.();sqlite.exec('BEGIN');try{const out=ops.map(o=>o.run());sqlite.exec('COMMIT');return out;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 const reopen=()=>createBridge(db,{now:()=>new Date(now),fetcher:()=>{throw Error('network forbidden');}}),core=reopen(),devices=[];
 for(const deviceId of ['fixture-mac','fixture-phone']){
  const token=await core.registerDevice({id:deviceId,label:deviceId,scopes:['user.context']}),d=await core.authenticateDevice(token.token);
  sqlite.prepare("INSERT INTO states(source_key,device_id,seq,observed_at,received_at,value_hash,body) VALUES(?,?,1,?,?,?,?)").run(deviceId+':device.status',deviceId,now.toISOString(),now.toISOString(),'fixture',JSON.stringify({value:{approvalNotifications:{routingProtocol:1,enabled:true,systemAuthorization:'authorized'}}}));
  await core.nativeCommands.setGrant({revision:1,capabilities:['item.create'],expiresAt:'2026-10-16T14:00:00.000Z'},d);devices.push(d);
 }
 const submit=async n=>(await core.nativeCommands.submit({version:1,commandId:id(n),deviceId:devices[0].id,kind:'item',action:'create',recordId:id(n+100),patch:{title:'ISOLATED ROUTING FIXTURE'},occurredAt:now.toISOString(),userRequest:'Isolated fixture, never real task'},'fixture-owner',{formOrigin:'submit_native_command'})).value;
 const config=async(d,values)=>core.nativeCommands.routing.configure({expectedRevision:(await core.nativeCommands.routing.read(d)).revision,...values},d);
 const decision=(r,extras={})=>({commandId:r.commandId,requestHash:r.requestHash,grantRevision:r.grantRevision,expectedRevision:null,decision:'accept',...extras});
 return{core,sqlite,devices,submit,config,decision,reopen,beforeBatch(fn){beforeBatch=fn;},failAudit(v){failAudit=v;},advance(ms){now=new Date(now.getTime()+ms);}};
}
const identity=r=>({commandId:r.commandId,requestHash:r.requestHash});
test('legacy target-only boundary remains until separate opt-in; clock devices cannot change routing',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices,r=await f.submit(1);
 assert.equal((await f.core.nativeCommands.approvalList({},phone)).commands.length,0);
 await assert.rejects(f.core.nativeCommands.approvalStatus({commandId:r.commandId},phone),e=>e.status===403);
 await assert.rejects(f.core.nativeCommands.routing.claim(identity(r),phone),e=>e.status===403);
 assert.equal((await f.core.nativeCommands.routing.claim(identity(r),mac)).maySubmit,true);
 await assert.rejects(f.config(phone,{primaryHere:true}),e=>e.status===403);
 const clock=await f.core.registerDevice({id:'clock',label:'fixture clock',scopes:['source.status']}),d=await f.core.authenticateDevice(clock.token);
 await assert.rejects(f.core.nativeCommands.routing.configure({expectedRevision:0,reviewOtherDevices:true},d),e=>e.status===403);
});
test('explicit opt-in exposes one request to both devices; one primary receives one frozen identity',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices;
 await f.config(phone,{reviewOtherDevices:true,primaryHere:true});const r=await f.submit(2);
 const listed=await f.core.nativeCommands.approvalList({},phone);assert.equal(listed.commands[0].commandId,r.commandId);assert.equal(listed.commands[0].reviewContext.reviewerDeviceId,phone.id);
 const [a,b]=await Promise.all([f.core.nativeCommands.routing.claim(identity(r),mac),f.core.nativeCommands.routing.claim(identity(r),phone)]);
 assert.equal(a.maySubmit,false);assert.equal(a.claimId,null);assert.equal(b.maySubmit,true);assert.equal(a.deviceId,phone.id);
 const restarted=await f.reopen().nativeCommands.routing.claim(identity(r),phone);assert.equal(restarted.claimId,b.claimId);assert.equal(restarted.policyRevision,b.policyRevision);assert.equal(b.beginSubmission,true);assert.equal(restarted.beginSubmission,false);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_approval_notifications').get().n,1);
});
test('switching the primary never reroutes a prior request or fails over when it is offline',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices;
 await f.config(phone,{reviewOtherDevices:true,primaryHere:true});const r=await f.submit(3),old=await f.core.nativeCommands.routing.claim(identity(r),phone);
 await f.config(mac,{reviewOtherDevices:true,primaryHere:true});
 const no=await f.core.nativeCommands.routing.claim(identity(r),mac);assert.equal(no.deviceId,phone.id);assert.equal(no.maySubmit,false);
 assert.equal((await f.core.nativeCommands.routing.claim(identity(r),phone)).claimId,old.claimId);
 const fresh=await f.core.nativeCommands.routing.claim(identity(await f.submit(4)),mac);assert.equal(fresh.deviceId,mac.id);assert.equal(fresh.maySubmit,true);
});
test('policy lost reply is idempotent and an optimistic conflict cannot change another device',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices,v={expectedRevision:0,reviewOtherDevices:true,primaryHere:true};
 const result=await f.core.nativeCommands.routing.configure(v,phone);assert.equal((await f.reopen().nativeCommands.routing.configure(v,phone)).revision,result.revision);
 await assert.rejects(f.core.nativeCommands.routing.configure(v,mac),e=>e.status===409);
 assert.equal((await f.core.nativeCommands.routing.read(mac)).primaryDeviceId,phone.id);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='approval_policy_changed'").get().n,1);
});
test('revoking cross-review or changing its grant immediately blocks reads and decisions',async t=>{
 const f=await fixture(t),[,phone]=f.devices;await f.config(phone,{reviewOtherDevices:true});const r=await f.submit(5);
 const p=await f.core.nativeCommands.approvalStatus({commandId:r.commandId},phone);
 await f.core.nativeCommands.setGrant({revision:2,capabilities:['item.create'],expiresAt:'2026-10-16T14:00:00.000Z'},phone);
 assert.equal((await f.core.nativeCommands.routing.read(phone)).reviewOtherDevices,false);
 await assert.rejects(f.core.nativeCommands.approvalStatus({commandId:r.commandId},phone),e=>e.status===403);
 await assert.rejects(f.core.nativeCommands.decideFromDevice(f.decision(r,{reviewerGrantRevision:p.reviewContext.grantRevision,reviewerPolicyRevision:p.reviewContext.policyRevision}),phone),e=>e.status===403);
 await f.config(phone,{reviewOtherDevices:true,primaryHere:true});await f.config(phone,{reviewOtherDevices:false});
 assert.equal((await f.core.nativeCommands.routing.read(phone)).primaryDeviceId,null);
 assert.equal((await f.core.nativeCommands.approvalList({},phone)).commands.length,0);
});
test('cross-device native and target decisions race to one persisted effect and converge results',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices;await f.config(phone,{reviewOtherDevices:true});const r=await f.submit(6),p=await f.core.nativeCommands.approvalStatus({commandId:r.commandId},phone);
 const v=f.decision(r,{reviewerGrantRevision:p.reviewContext.grantRevision,reviewerPolicyRevision:p.reviewContext.policyRevision});
 const outcomes=await Promise.allSettled([f.core.nativeCommands.decideFromDevice(v,phone),f.core.nativeCommands.decideFromDevice({...f.decision(r),decision:'decline'},mac)]);
 assert.equal(outcomes.filter(o=>o.status==='fulfilled').length,1);
 const state=(await f.core.nativeCommands.status({commandId:r.commandId},'fixture-owner')).state;assert.ok(['queued','declined'].includes(state));
 assert.equal((await f.core.nativeCommands.approvalList({},phone)).commands[0].state,state);
 assert.equal((await f.core.nativeCommands.approvalList({},mac)).commands[0].state,state);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_approval_decision'").get().n,1);
 if(state==='queued')assert.equal((await f.core.nativeCommands.decideFromDevice(v,phone)).state,'queued');
});
test('review permission revocation racing with the decision UPDATE prevents authorization',async t=>{
 const f=await fixture(t),[,phone]=f.devices;await f.config(phone,{reviewOtherDevices:true});const r=await f.submit(7),p=await f.core.nativeCommands.approvalStatus({commandId:r.commandId},phone);
 f.beforeBatch(()=>f.sqlite.prepare("UPDATE native_approval_policy SET body=?").run(JSON.stringify({primaryDeviceId:null,reviewers:[]})));
 await assert.rejects(f.core.nativeCommands.decideFromDevice(f.decision(r,{reviewerGrantRevision:p.reviewContext.grantRevision,reviewerPolicyRevision:p.reviewContext.policyRevision}),phone));
 assert.equal((await f.core.nativeCommands.status({commandId:r.commandId},'fixture-owner')).state,'awaiting_confirmation');
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_approval_decision'").get().n,0);
});
test('failed audit persistence rolls back policy and notification receipts',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices;f.failAudit(true);
 await assert.rejects(f.config(phone,{reviewOtherDevices:true}));assert.equal((await f.core.nativeCommands.routing.read(phone)).revision,0);
 f.failAudit(false);const r=await f.submit(8),claim=await f.core.nativeCommands.routing.claim(identity(r),mac);f.failAudit(true);
 await assert.rejects(f.core.nativeCommands.routing.receipt({...identity(r),claimId:claim.claimId,state:'system_submitted'},mac));
 assert.equal(f.sqlite.prepare('SELECT state FROM native_approval_notifications').get().state,'reserved');
});
test('system submission, unknown and clicks are distinct and bound; late failure never downgrades evidence',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices,r=await f.submit(9),c=await f.core.nativeCommands.routing.claim(identity(r),mac),v={...identity(r),claimId:c.claimId};
 await assert.rejects(f.core.nativeCommands.routing.receipt({...v,state:'system_submitted'},phone),e=>e.status===403);
 await assert.rejects(f.core.nativeCommands.routing.receipt({...v,claimId:id(999),state:'clicked'},mac),e=>e.status===403);
 assert.equal((await f.core.nativeCommands.routing.receipt({...v,state:'unknown'},mac)).state,'unknown');
 assert.equal((await f.reopen().nativeCommands.routing.claim(identity(r),mac)).maySubmit,false);
 const submitted=await f.core.nativeCommands.routing.receipt({...v,state:'system_submitted'},mac);assert.ok(submitted.systemSubmittedAt);assert.equal(submitted.userSeen,'unknown');
 assert.equal((await f.core.nativeCommands.routing.receipt({...v,state:'failed'},mac)).state,'system_submitted');
 assert.equal((await f.core.nativeCommands.routing.receipt({...v,state:'clicked'},mac)).state,'clicked');
 assert.equal((await f.core.nativeCommands.routing.receipt({...v,state:'system_submitted'},mac)).state,'clicked');
 assert.equal((await f.core.nativeCommands.status({commandId:r.commandId},'fixture-owner')).state,'awaiting_confirmation');
});
test('expired, cancelled, wrong-hash or target-revoked requests never become a notification grant',async t=>{
 const f=await fixture(t),[mac]=f.devices,r=await f.submit(10);
 await assert.rejects(f.core.nativeCommands.routing.claim({...identity(r),requestHash:'wrong'},mac),e=>e.status===409);
 await f.core.nativeCommands.decideFromDevice({...f.decision(r),decision:'decline'},mac);
 assert.equal((await f.core.nativeCommands.routing.claim(identity(r),mac)).maySubmit,false);
 const e=await f.submit(11);f.advance(86400001);assert.equal((await f.core.nativeCommands.routing.claim(identity(e),mac)).maySubmit,false);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_approval_notifications').get().n,0);
});

test('mixed-version or stale devices block primary selection; unknown route never becomes a later duplicate',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices;
 f.sqlite.prepare("UPDATE states SET body=? WHERE device_id=?").run(JSON.stringify({value:{approvalNotifications:{enabled:true}}}),mac.id);
 assert.equal((await f.core.nativeCommands.routing.read(phone)).routingReadiness.ready,false);
 await assert.rejects(f.config(phone,{reviewOtherDevices:true,primaryHere:true}),e=>e.status===409);
 f.sqlite.prepare("UPDATE states SET body=? WHERE device_id=?").run(JSON.stringify({value:{approvalNotifications:{routingProtocol:1,enabled:true,systemAuthorization:'authorized'}}}),mac.id);
 await f.config(phone,{reviewOtherDevices:true,primaryHere:true});
 f.advance(901000);const r=await f.submit(21);
 const c=await f.core.nativeCommands.routing.claim(identity(r),phone);assert.equal(c.state,'unknown');assert.equal(c.maySubmit,false);assert.equal(c.beginSubmission,false);
 f.sqlite.prepare("UPDATE states SET observed_at=?,received_at=?").run('2026-10-15T14:15:01.000Z','2026-10-15T14:15:01.000Z');
 const later=await f.core.nativeCommands.routing.claim(identity(r),phone);assert.equal(later.state,'unknown');assert.equal(later.maySubmit,false);
 assert.equal((await f.core.nativeCommands.routing.claim(identity(r),mac)).maySubmit,false);
});
test('old pending requests keep original alert destination and shared list can be locally disabled',async t=>{
 const f=await fixture(t),[mac,phone]=f.devices,r=await f.submit(22);f.advance(1);
 await f.config(phone,{reviewOtherDevices:true,primaryHere:true});
 assert.equal((await f.core.nativeCommands.approvalList({includeShared:false},phone)).commands.length,0);
 const other=await f.core.nativeCommands.routing.claim(identity(r),phone);assert.equal(other.deviceId,mac.id);assert.equal(other.beginSubmission,false);
 const first=await f.core.nativeCommands.routing.claim(identity(r),mac);assert.equal(first.beginSubmission,true);
 assert.equal((await f.core.nativeCommands.routing.claim(identity(r),mac)).beginSubmission,false);
});

test('primary selection does not silently enable notifications or assume system permission',async t=>{
 const f=await fixture(t),[,phone]=f.devices;
 f.sqlite.prepare("UPDATE states SET body=? WHERE device_id=?").run(JSON.stringify({value:{approvalNotifications:{routingProtocol:1,enabled:false,systemAuthorization:'denied'}}}),phone.id);
 const status=await f.core.nativeCommands.routing.read(phone);assert.equal(status.routingReadiness.ready,true);
 await assert.rejects(f.config(phone,{reviewOtherDevices:true,primaryHere:true}),e=>e.status===409);
 assert.equal((await f.core.nativeCommands.routing.read(phone)).primaryDeviceId,null);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM native_approval_policy").get().n,0);
});
