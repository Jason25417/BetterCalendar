import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import * as bridge from '../lib/bridge.mjs';
import * as presentation from '../lib/confirmation-presentation.mjs';
const ts=createRequire(import.meta.url)('typescript');
const source=ts.transpileModule(readFileSync(new URL('../app/api/[...path]/route.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const id='12345678-1234-4234-8234-000000003800';
async function fixture(t){
 const sqlite=new DatabaseSync(':memory:');t.after(()=>sqlite.close());
 for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 const prepare=sql=>{let args=[];return {bind(...a){args=a;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return {results:sqlite.prepare(sql).all(...args)};},run(){return sqlite.prepare(sql).run(...args);}};};
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const out=ops.map(o=>o.run());sqlite.exec('COMMIT');return out;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 const core=bridge.createBridge(db,{now:()=>new Date('2026-10-14T12:00:00.000Z'),fetcher:()=>{throw Error('network prohibited');}});
 const device=await core.registerDevice({id:'fixture-target',label:'Isolated API fixture',scopes:['user.context']});const d=await core.authenticateDevice(device.token);
 await core.nativeCommands.setGrant({revision:1,capabilities:['item.create'],expiresAt:'2026-10-15T12:00:00.000Z'},d);
 const request={version:1,commandId:id,deviceId:d.id,kind:'item',action:'create',recordId:'12345678-1234-4234-8234-000000003801',patch:{title:'Isolated API fixture'},occurredAt:'2026-10-14T12:00:00.000Z',userRequest:'Isolated test, no real task'};
 const proposal=await core.nativeCommands.submit(request,'fixture-owner',{formOrigin:'submit_native_command'});
 const modules={'@/lib/service':{service:()=>core},'@/lib/bridge.mjs':bridge,'@/lib/confirmation-presentation.mjs':presentation,'cloudflare:workers':{env:{}}};
 const exports={};vm.runInNewContext(source,{exports,require(n){assert.ok(modules[n],n);return modules[n];},Response,TextEncoder});
 const post=async(path,body={},token=device.token)=>{
  const response=await exports.POST(new Request('https://fixture.invalid/api/'+path,{method:'POST',headers:token?{Authorization:'Bearer '+token}:{},body:JSON.stringify(body)}),{params:Promise.resolve({path:path.split('/')})});
  return {status:response.status,body:await response.json()};
 };
 return{core,sqlite,d,request,proposal,post};
}
test('device HTTP list/read/approve/reject use one request and return conflict with latest state',async t=>{
 const f=await fixture(t);assert.equal((await f.post('native/approvals',{},null)).status,401);
 const listed=await f.post('native/approvals');assert.equal(listed.status,200);assert.equal(listed.body.commands.length,1);
 const read=await f.post('native/approval/read',{commandId:id});assert.equal(read.body.display.deviceLabel,'Isolated API fixture');
 const body={commandId:id,requestHash:f.proposal.value.requestHash,grantRevision:1,expectedRevision:null,decision:'accept'};
 assert.equal((await f.post('native/approval/decide',body)).body.state,'queued');
 assert.equal((await f.post('native/approval/decide',body)).body.state,'queued');
 const opposite=await f.post('native/approval/decide',{...body,decision:'decline'});assert.equal(opposite.status,409);assert.equal(opposite.body.current.state,'queued');
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_approval_decision'").get().n,1);
 const claim={commandId:id,requestHash:body.requestHash,attemptId:'12345678-1234-4234-8234-000000003899'};
 assert.equal((await f.post('native/claim',claim)).body.state,'dispatching');
 const receipt={...claim,outcome:'applied',receipt:{saved:true,evidence:'isolated_device_simulation'}};
 assert.equal((await f.post('native/receipt',receipt)).body.state,'applied');
 assert.equal((await f.post('native/receipt',receipt)).body.state,'applied');
 assert.equal((await f.post('native/approval/read',{commandId:id})).body.state,'applied');
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_result'").get().n,1);

});
test('clock-only device and arbitrary model approval fields cannot reach native confirmation',async t=>{
 const f=await fixture(t),clock=await f.core.registerDevice({id:'clock',label:'Clock fixture',scopes:['source.status']});
 assert.equal((await f.post('native/approvals',{},clock.token)).status,403);
 assert.equal((await f.post('native/approval/read',{commandId:id},clock.token)).status,403);
 assert.equal((await f.post('native/approval/decide',{commandId:id,userConfirmed:true})).status,400);
 assert.equal((await f.core.nativeCommands.status({commandId:id},'fixture-owner')).state,'awaiting_confirmation');
});
test('missing or mismatching item snapshot blocks approve but allows a concrete native rejection',async t=>{
 const f=await fixture(t);
 await f.core.nativeCommands.setGrant({revision:2,capabilities:['item.update'],expiresAt:'2026-10-15T12:00:00.000Z'},f.d);
 const request={...f.request,commandId:'12345678-1234-4234-8234-000000003802',action:'update',expectedRevision:'missing-fixture-version'};
 const s=await f.core.nativeCommands.submit(request,'fixture-owner',{formOrigin:'submit_native_command'});
 const read=await f.post('native/approval/read',{commandId:request.commandId});assert.ok(read.body.displayError);
 const body={commandId:request.commandId,requestHash:s.value.requestHash,grantRevision:2,expectedRevision:request.expectedRevision,decision:'accept'};
 assert.equal((await f.post('native/approval/decide',body)).status,409);
 assert.equal((await f.post('native/approval/decide',{...body,decision:'decline'})).body.state,'declined');
});
test('native read and human decision resolve uppercase directory UUID with unchanged request hash and revision',async t=>{
 const f=await fixture(t),recordId='abcdefab-cdef-4abc-8def-abcdefabcdef';
 await f.core.nativeCommands.setGrant({revision:2,capabilities:['item.update'],expiresAt:'2026-10-15T12:00:00.000Z'},f.d);
 const request={...f.request,commandId:'12345678-1234-4234-8234-000000004001',recordId,action:'update',expectedRevision:'a'.repeat(64)};
 const s=await f.core.nativeCommands.submit(request,'fixture-owner',{formOrigin:'submit_native_command'});
 let revision=request.expectedRevision;
 f.core.readPoolRecords=async()=>({complete:true,records:[{id:recordId.toUpperCase(),revision,values:{title:'Isolated before title'}}],hasMore:false});
 const read=await f.post('native/approval/read',{commandId:request.commandId});
 assert.equal(read.status,200);assert.equal(read.body.displayError,null);
 assert.equal(read.body.request.recordId,recordId);assert.equal(read.body.requestHash,s.value.requestHash);
 assert.deepEqual(read.body.display.before,{title:'Isolated before title'});
 const body={commandId:request.commandId,requestHash:s.value.requestHash,grantRevision:2,expectedRevision:request.expectedRevision,decision:'accept'};
 revision='b'.repeat(64);
 assert.equal((await f.post('native/approval/decide',body)).status,409);
 assert.equal((await f.core.nativeCommands.status({commandId:request.commandId},'fixture-owner')).state,'awaiting_confirmation');
 revision=request.expectedRevision;
 assert.equal((await f.post('native/approval/decide',body)).body.state,'queued');
 assert.equal((await f.post('native/approval/decide',body)).body.state,'queued');
 const latest=await f.core.nativeCommands.status({commandId:request.commandId},'fixture-owner');
 assert.equal(latest.requestHash,s.value.requestHash);assert.equal(latest.request.expectedRevision,request.expectedRevision);
 assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_approval_decision'").get().n,1);
});
