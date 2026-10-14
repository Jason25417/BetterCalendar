import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import * as bridge from '../lib/bridge.mjs';
import * as confirmation from '../lib/native-confirmation.mjs';
import * as commands from '../lib/native-commands.mjs';
import * as capabilities from '../lib/mcp-client-capabilities.mjs';
import * as form from '../lib/native-form-confirmation.mjs';
import * as research from '../lib/research.mjs';
import * as presentation from '../lib/confirmation-presentation.mjs';
import * as formResponse from '../lib/native-form-response.mjs';
const ts=createRequire(import.meta.url)('typescript');
const Ajv=createRequire(import.meta.url)('ajv');
const routeSource=ts.transpileModule(readFileSync(new URL('../app/mcp/route.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const meta={'io.modelcontextprotocol/protocolVersion':'2026-07-28','io.modelcontextprotocol/clientCapabilities':{elicitation:{}}};
const uuid=n=>`12345678-1234-4234-8234-${String(n).padStart(12,'0')}`;
async function fixture(t,{confirmationChannel='chat_form',fetcher=()=>{throw Error('test forbids network');}}={}){
 const sqlite=new DatabaseSync(':memory:');t.after(()=>sqlite.close());
 for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 let failReturned=false,beforeRecord=null,failKind=null,now=new Date('2026-10-13T10:00:00.000Z');
 const prepare=sql=>{let args=[];return {bind(...v){args=v;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return {results:sqlite.prepare(sql).all(...args)};},run(){if(sql.startsWith('INSERT INTO research_log')){if(beforeRecord&&args[1]===beforeRecord.kind){const hook=beforeRecord;beforeRecord=null;hook.fn();}if(args[1]===failKind){failKind=null;throw Error('isolated audit persistence failure');}if(failReturned&&args[1]==='call_returned'){failReturned=false;throw Error('isolated persistence failure');}}return sqlite.prepare(sql).run(...args);}};};
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const out=ops.map(op=>op.run());sqlite.exec('COMMIT');return out;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 const reopen=()=>bridge.createBridge(db,{now:()=>now,fetcher,confirmationChannel});
 let core=reopen();const logs=[];
 const modules={'@/lib/confirmation-presentation.mjs':presentation,'@/lib/service':{service:()=>core},'@/lib/bridge.mjs':bridge,'@/lib/dot-instructions':{dotInstructions:'isolated route fixture'},'@/lib/native-confirmation.mjs':confirmation,'@/lib/native-commands.mjs':commands,'@/lib/mcp-client-capabilities.mjs':capabilities,'@/lib/native-form-confirmation.mjs':form,'@/lib/research.mjs':research,'@/lib/native-form-response.mjs':formResponse};
 const exports={};vm.runInNewContext(routeSource,{exports,require(name){assert.ok(modules[name],`unexpected import ${name}`);return modules[name];},Response,TextEncoder,crypto,console:{info(...args){logs.push(args);},warn(...args){logs.push(args);}}});
 let rpcId=0;
 const rpc=async(method,params,owner='fixture-owner')=>{
  const response=await exports.POST(new Request('https://fixture.invalid/mcp',{method:'POST',headers:{'Content-Type':'application/json',...(owner?{'oai-authenticated-user-id':owner}:{})},body:JSON.stringify({jsonrpc:'2.0',id:++rpcId,method,params})}));
  return {status:response.status,body:await response.json()};
 };
 const device=await core.registerDevice({id:'isolated-device',label:'In-memory fixture',scopes:['user.context']});
 const d=await core.authenticateDevice(device.token);
 await core.nativeCommands.setGrant({revision:1,capabilities:['item.create','timer.start'],expiresAt:'2026-10-14T10:00:00.000Z'},d);
 const request=(n=1)=>({version:1,commandId:uuid(n),deviceId:d.id,kind:'item',action:'create',recordId:uuid(100+n),patch:{title:'Isolated route fixture, never a real task'},occurredAt:now.toISOString(),expiresAt:'2026-10-13T11:00:00.000Z',userRequest:'Isolated simulated human request'});
 const call=(name,args,extra={},owner)=>rpc('tools/call',{name,arguments:args,_meta:meta,...extra},owner);
 return {sqlite,logs,d,request,rpc,call,get core(){return core;},restart(){core=reopen();},failResult(){failReturned=true;},beforeRecord(kind,fn){beforeRecord={kind,fn};},failRecordKind(kind){failKind=kind;},advance(ms){now=new Date(now.getTime()+ms);}};
}
const reply=state=>({requestState:state,inputResponses:{bc_native_confirmation:{action:'accept',content:{confirm:true}}}});
test('read-only preview accepts all host outcomes without approving or reopening the original command',async t=>{
 const f=await fixture(t),v=f.request(95),submitted=await f.call('submit_native_command',v);
 await f.call('submit_native_command',v,{requestState:submitted.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 const before=f.sqlite.prepare('SELECT * FROM native_requests').get();
 for(const action of ['accept','cancel','decline']){
  const initial=await f.call('preview_native_confirmation',{commandId:v.commandId});
  assert.equal(initial.body.result.resultType,'input_required');assert.match(initial.body.result.inputRequests.bc_native_confirmation.params.message,/只读显示测试/);
  const state=initial.body.result.requestState;
  assert.ok((await f.call('submit_native_command',v,reply(state))).body.error);
  const result=await f.call('preview_native_confirmation',{commandId:v.commandId},{requestState:state,inputResponses:{bc_native_confirmation:{action,...(action==='accept'?{content:{confirm:true}}:{})}}});
  assert.equal(result.body.result.structuredContent.executed,false);assert.equal(result.body.result.structuredContent.originalState,'cancelled');
  assert.deepEqual(f.sqlite.prepare('SELECT * FROM native_requests').get(),before);
 }
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 assert.ok((await f.call('preview_native_confirmation',{commandId:v.commandId},{},'other-owner')).body.error);
 const list=await f.rpc('tools/list',{}),tool=list.body.result.tools.find(t=>t.name==='preview_native_confirmation');assert.equal(tool.annotations.readOnlyHint,true);
 for(const name of ['submit_native_command','task_command'])assert.equal(list.body.result.tools.find(t=>t.name===name)._meta,undefined);
});
test('cached record_context preview adapter never saves context or grants an operation',async t=>{
 const f=await fixture(t),v=f.request(96),first=await f.call('submit_native_command',v);
 await f.call('submit_native_command',v,{requestState:first.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 const a={id:'bc-preview:'+v.commandId,kind:'bc.confirmation.preview',body:{commandId:v.commandId},assertion:'user',confidence:'unknown',basis:[]};
 const before=f.sqlite.prepare('SELECT * FROM native_requests').get();
 const shown=await f.call('record_context',a);assert.equal(shown.body.result.resultType,'input_required');
 const closed=await f.call('record_context',a,{requestState:shown.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.equal(closed.body.result.structuredContent.executed,false);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM notes').get().n,0);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 assert.deepEqual(f.sqlite.prepare('SELECT * FROM native_requests').get(),before);
 for(const bad of [{...a,body:{commandId:v.commandId,patch:{note:'not allowed'}}},{...a,confidence:'high'},{...a,supersedes:'other'}])assert.ok((await f.call('record_context',bad)).body.error);
});
test('actual continuation tolerates recognized transport metadata without using it for authority',async t=>{
 const f=await fixture(t),v=f.request(97),first=await f.call('submit_native_command',v);
 const response={action:'accept',content:{confirm:true},resultType:'complete',_meta:{privateFixture:'not-recorded',userConfirmed:true,patch:{title:'must-not-apply'}}};
 const accepted=await f.call('submit_native_command',v,{requestState:first.body.result.requestState,inputResponses:{bc_native_confirmation:response}});
 assert.equal(accepted.body.result.structuredContent.state,'queued');assert.deepEqual(accepted.body.result.structuredContent.request.patch,v.patch);
 const event=(await f.core.research.read({limit:100})).entries.find(e=>e.kind==='native_confirmation_response_received');
 assert.equal(event.body.responseShape.resultTypeType,'string');assert.equal(event.body.responseShape.metadataType,'object');
 assert.equal(JSON.stringify(event).includes('not-recorded'),false);
});
test('choice and text-review previews accept typed responses and never write activities or commands',async t=>{
 const f=await fixture(t),v=f.request(98),first=await f.call('submit_native_command',v);
 await f.call('submit_native_command',v,{requestState:first.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 const before=f.sqlite.prepare('SELECT * FROM native_requests').get();
 for(const variant of ['choice','review']){
  const a={id:'bc-preview:'+v.commandId,kind:'bc.confirmation.preview',body:{commandId:v.commandId,variant},assertion:'user',confidence:'unknown',basis:[]};
  const preview=await f.call('record_context',a),schema=preview.body.result.inputRequests.bc_native_confirmation.params.requestedSchema;
  assert.equal(new Ajv().compile(schema)(variant==='choice'?{confirm:'不执行'}:{confirm:false,review:'display only'}),true);
  const content=variant==='choice'?{confirm:'确认显示测试'}:{confirm:true,review:schema.properties.review.default};
  const outcome=await f.call('record_context',a,{requestState:preview.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'accept',content,resultType:'complete'}}});
  assert.equal(outcome.body.result.structuredContent.executed,false);
  assert.deepEqual(f.sqlite.prepare('SELECT * FROM native_requests').get(),before);
 }
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM notes').get().n,0);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
});
test('minute delivery and repeated status reads do not cancel, rotate or approve a pending native form',async t=>{
 const callbacks=[];
 const f=await fixture(t,{fetcher:async(url,options)=>{
  if(url.includes('dns-query'))return Response.json({Status:0,Answer:[{type:1,data:'104.18.1.1'}]});
  const event=JSON.parse(options.body);
  if(event.type==='verification')return Response.json({challenge:event.challenge});
  callbacks.push(event);return Response.json({});
 }}),request=f.request(),first=await f.call('submit_native_command',request);
 const original=f.sqlite.prepare('SELECT approval_hash FROM native_requests').get().approval_hash;
 const enrolled=await f.core.registerDevice({id:'synthetic-observer',label:'In-memory event fixture',scopes:['mac.activity']});
 const d=await f.core.authenticateDevice(enrolled.token);
 await f.core.subscribe({name:'state.minute_changed',arguments:{},delivery:{mode:'webhook',url:'https://api.openai.com/isolated-form-event',secret:'whsec_'+Buffer.alloc(32,7).toString('base64')}},'fixture-owner');
 await f.core.ingest({observations:[{schemaVersion:1,eventId:'isolated-change',source:'mac.activity',sequence:1,observedAt:'2026-10-13T10:00:00.000Z',expiresAt:null,assertion:'observed',value:{synthetic:true}}]},d);
 assert.equal((await f.call('flush_minute_changes',{})).body.result.structuredContent.delivered,1);
 f.restart();assert.equal((await f.call('flush_minute_changes',{})).body.result.structuredContent.delivered,0);
 for(let n=0;n<3;n++)assert.equal((await f.call('read_native_command_status',{commandId:request.commandId})).body.result.structuredContent.state,'awaiting_confirmation');
 assert.equal(f.sqlite.prepare('SELECT approval_hash FROM native_requests').get().approval_hash,original);
 assert.equal(callbacks.length,1);assert.equal(callbacks[0].name,'state.minute_changed');
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 const research=await f.core.research.read({limit:100});
 const safe=JSON.stringify({research,logs:f.logs});
 assert.equal(safe.includes(first.body.result.requestState),false);
 assert.equal(safe.includes('whsec_'),false);assert.equal(safe.includes('/isolated-form-event'),false);
});
test('actual POST route handles MRTR, one device receipt and lost-response retry without secret leakage',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v);
 assert.equal(first.body.result.resultType,'input_required');
 const state=first.body.result.requestState;assert.equal(typeof state,'string');
 assert.equal(first.body.result.inputRequests.bc_native_confirmation.params.requestedSchema.properties.confirm.default,false);
 assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 f.restart();const approved=await f.call('submit_native_command',v,reply(state));
 assert.equal(approved.body.result.resultType,'complete');
 const queued=approved.body.result.structuredContent;assert.equal(queued.state,'queued');
 assert.equal(new Ajv({allowUnionTypes:true}).compile(confirmation.nativeCommandOutputSchema)(queued),true);
 assert.equal(JSON.stringify(approved).includes(state),false);
 const claim={commandId:v.commandId,requestHash:queued.requestHash,attemptId:uuid(999)};
 await f.core.nativeCommands.claim(claim,f.d);
 await f.core.nativeCommands.receipt({...claim,outcome:'applied',receipt:{saved:true,authority:'isolated_device_fixture'}},f.d);
 const retry=await f.call('submit_native_command',v,reply(state));
 assert.equal(retry.body.result.structuredContent.state,'applied');assert.equal(retry.body.result.structuredContent.userSeen,'unknown');
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_requests').get().n,1);
 const research=await f.core.research.read({limit:100});
 const trace=research.entries.filter(e=>e.kind==='call_started');
 const confirmationCall=trace.find(e=>e.body.arguments.confirmation);
 assert.equal(confirmationCall.body.arguments.confirmation.transport,'mcp_form');assert.equal(confirmationCall.body.arguments.confirmation.confirmed,undefined);
 const raw=await f.core.research.evidence({nativeCommandIds:[v.commandId]});
 assert.equal(raw.nativeCommands[0].body.userRequest,v.userRequest);
 assert.equal(JSON.stringify({research,raw,logs:f.logs}).includes(state),false);
});
test('route rejects model confirmation flags, altered envelopes and cross-owner continuation before execution',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 const candidates=[
  ['submit_native_command',{...v,userConfirmed:true},{},undefined],
  ['submit_native_command',{...v,requestState:state,inputResponses:reply(state).inputResponses},{},undefined],
  ['submit_native_command',{...v,patch:{title:'tampered'}},reply(state),undefined],
  ['task_command',v,reply(state),undefined],
  ['submit_native_command',v,reply(state),'different-owner'],
  ['submit_native_command',v,{...reply(state),requestState:state+'tampered'},undefined],
  ['submit_native_command',v,{...reply(state),_meta:{}},undefined],
  ['submit_native_command',v,{requestState:state},undefined],
  ['read_native_command_status',{commandId:v.commandId},reply(state),undefined],
 ];
 for(const [name,args,extra,owner] of candidates){const result=await f.call(name,args,extra,owner);assert.ok(result.body.error,`${name} must reject`);}
 assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 assert.equal((await f.core.nativeCommands.status({commandId:v.commandId},'fixture-owner')).approvedAt,null);
});
test('route cancellation does not dispatch or silently renew the consumed confirmation',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 const canceled=await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.equal(canceled.body.result.resultType,'complete');assert.equal(canceled.body.result.structuredContent.approvedAt,null);
 assert.equal(canceled.body.result.structuredContent.state,'cancelled');
 assert.equal('requestState' in canceled.body.result,false);
 assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 f.restart();
 const sameCancel={requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}};
 assert.equal((await f.call('submit_native_command',v,sameCancel)).body.result.structuredContent.state,'cancelled');
 const refreshed=await f.call('submit_native_command',v);assert.equal(refreshed.body.result.resultType,'complete');
 assert.equal(refreshed.body.result.structuredContent.state,'cancelled');assert.equal('requestState' in refreshed.body.result,false);
 assert.equal(new Ajv({allowUnionTypes:true}).compile(confirmation.nativeCommandOutputSchema)(refreshed.body.result.structuredContent),true);
 assert.ok((await f.call('submit_native_command',v,reply(state))).body.error);
});
test('host cancellation before expiry records unknown cause, never a confirmed user gesture',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 f.advance(40000);
 const canceled=await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.equal(canceled.body.result.structuredContent.state,'cancelled');assert.equal(canceled.body.result.structuredContent.approvedAt,null);
 const research=await f.core.research.read({limit:100}),call=research.entries.find(e=>e.kind==='call_started'&&e.body.arguments.confirmation);
 assert.deepEqual(JSON.parse(JSON.stringify(call.body.arguments.confirmation)),{transport:'mcp_form',source:'host_response',userGesture:'unknown',cause:'unknown'});
 assert.equal(JSON.stringify(research).includes(state),false);assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 f.restart();assert.equal((await f.call('submit_native_command',v)).body.result.structuredContent.state,'cancelled');
});
test('POST late cancel preserves expired status and does not publish another confirmation',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 f.advance(3600001);
 const late=await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.equal(late.body.result.resultType,'complete');assert.equal(late.body.result.structuredContent.state,'expired');assert.equal('requestState' in late.body.result,false);
 assert.equal(late.body.result.structuredContent.approvedAt,null);assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 const repeated=await f.call('submit_native_command',v);assert.equal(repeated.body.result.structuredContent.state,'expired');assert.equal('requestState' in repeated.body.result,false);
});
test('research result persistence failure returns error after approval; same command recovers without double execution',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 f.failResult();const lost=await f.call('submit_native_command',v,reply(state));assert.ok(lost.body.error);
 assert.equal('result' in lost.body,false);
 f.restart();const status=await f.call('read_native_command_status',{commandId:v.commandId});assert.equal(status.body.result.structuredContent.state,'queued');
 const retry=await f.call('submit_native_command',v,reply(state));assert.equal(retry.body.result.structuredContent.state,'queued');
 assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,1);
});
test('late cancellation cannot undo an accepted command; refusal survives response loss and restart',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 const accepted=await f.call('submit_native_command',v,reply(state));const approvedAt=accepted.body.result.structuredContent.approvedAt;
 const late=await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.ok(late.body.error);assert.equal((await f.core.nativeCommands.status({commandId:v.commandId},'fixture-owner')).approvedAt,approvedAt);
 const other=f.request(2),pending=await f.call('submit_native_command',other),decline={requestState:pending.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'decline'}}};
 f.failResult();assert.ok((await f.call('submit_native_command',other,decline)).body.error);
 f.restart();assert.equal((await f.call('submit_native_command',other,decline)).body.result.structuredContent.state,'declined');
 const again=await f.call('submit_native_command',other);assert.equal(again.body.result.structuredContent.state,'declined');
 assert.equal('requestState' in again.body.result,false);assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,1);
});
test('route preserves legacy widget isolation and timer compatibility; unauthenticated form cannot mutate',async t=>{
 const f=await fixture(t),v=f.request();
 const unauth=await f.call('submit_native_command',v,{},null);assert.equal(unauth.status,401);assert.ok(unauth.body.error);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_requests').get().n,0);
 const legacy=await f.call('submit_native_command',v,{_meta:{}});assert.equal(legacy.body.result.resultType,'complete');
 assert.ok(legacy.body.result._meta.approval.token);assert.equal(JSON.stringify(legacy.body.result.structuredContent).includes(legacy.body.result._meta.approval.token),false);
 const timer={commandId:uuid(2),deviceId:f.d.id,action:'start',title:'Isolated timer',occurredAt:v.occurredAt,expiresAt:v.expiresAt,userRequest:v.userRequest};
 const first=await f.call('task_command',timer);assert.equal(first.body.result.resultType,'input_required');
 const accepted=await f.call('task_command',timer,reply(first.body.result.requestState));assert.equal(accepted.body.result.structuredContent.state,'queued');
 const list=await f.rpc('tools/list',{});
 const submit=list.body.result.tools.find(t=>t.name==='submit_native_command');
 assert.equal(submit.inputSchema.additionalProperties,false);assert.equal('requestState' in submit.inputSchema.properties,false);assert.equal('inputResponses' in submit.inputSchema.properties,false);
});

test('form finalization rejects stale pending snapshots after research persistence changes expiry, grant, closure or nonce',async t=>{
 for(const phase of ['call_returned','native_confirmation_prepared'])for(const mode of ['expiry','revocation','closure','rotation']){
  const f=await fixture(t),v=f.request();
  f.beforeRecord(phase,()=>{
   if(mode==='expiry')f.advance(3600001);
   if(mode==='revocation')f.sqlite.prepare('UPDATE native_grants SET revision=revision+1 WHERE device_id=?').run(v.deviceId);
   if(mode==='closure')f.sqlite.prepare("UPDATE native_requests SET state='cancelled' WHERE command_id=?").run(v.commandId);
   if(mode==='rotation')f.sqlite.prepare("UPDATE native_requests SET approval_hash='isolated-other-challenge' WHERE command_id=?").run(v.commandId);
  });
  const result=await f.call('submit_native_command',v);
  assert.notEqual(result.body.result?.resultType,'input_required',`${phase}/${mode}`);
  if(mode==='rotation')assert.match(result.body.error.message,/凭据已更新/);
  else {
   const value=result.body.result.structuredContent;
   assert.equal(value.state,{expiry:'expired',revocation:'revoked',closure:'cancelled'}[mode]);
   assert.equal(value.approvedAt,null);assert.equal('approval' in (result.body.result._meta??{}),false);
   assert.equal(new Ajv({allowUnionTypes:true}).compile(confirmation.nativeCommandOutputSchema)(value),true);
   const returned=f.sqlite.prepare('SELECT body FROM research_log WHERE call_id=?').get(value.research.callId);
   assert.equal(JSON.parse(returned.body).tool,'mcp/confirmation_finalize');
  }
  assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 }
});
test('prepared audit failure prevents publishing a form and response audit failure cannot masquerade as applied confirmation',async t=>{
 const f=await fixture(t),unpublished=f.request();f.failRecordKind('native_confirmation_prepared');
 assert.ok((await f.call('submit_native_command',unpublished)).body.error);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM research_log WHERE kind=?').get('native_confirmation_prepared').n,0);
 const recovered=await f.call('submit_native_command',unpublished);
 assert.equal(recovered.body.result.resultType,'complete');assert.equal('requestState' in recovered.body.result,false);
 const v=f.request(92);
 const first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 f.failRecordKind('native_confirmation_response_received');
 assert.ok((await f.call('submit_native_command',v,reply(state))).body.error);
 assert.equal((await f.core.nativeCommands.status({commandId:v.commandId},'fixture-owner')).state,'awaiting_confirmation');
 assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
 // Same nonce/request may retry its synthetic response; no new request or execution.
 f.failRecordKind('native_confirmation_response_processed');
 assert.ok((await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}})).body.error);
 assert.equal((await f.core.nativeCommands.status({commandId:v.commandId},'fixture-owner')).state,'cancelled');
 const retry=await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.equal(retry.body.result.structuredContent.state,'cancelled');assert.equal(retry.body.result.structuredContent.approvedAt,null);
});
test('pending retry does not rotate a nonce or publish another form after reconstruction',async t=>{
 const f=await fixture(t),v=f.request(),first=await f.call('submit_native_command',v);
 const originalHash=f.sqlite.prepare('SELECT approval_hash FROM native_requests').get().approval_hash;
 f.restart();const second=await f.call('submit_native_command',v);
 assert.equal(second.body.result.resultType,'complete');assert.equal('requestState' in second.body.result,false);
 assert.equal(f.sqlite.prepare('SELECT approval_hash FROM native_requests').get().approval_hash,originalHash);
 const closed=await f.call('submit_native_command',v,{requestState:first.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.equal(closed.body.result.structuredContent.state,'cancelled');
 assert.equal((await f.call('submit_native_command',v)).body.result.structuredContent.state,'cancelled');
 const entries=(await f.core.research.read({limit:100})).entries,prepared=entries.filter(e=>e.kind==='native_confirmation_prepared');
 assert.equal(prepared.length,1);assert.equal(prepared[0].body.commandId,v.commandId);assert.equal(prepared[0].body.hostDisplayed,'unknown');
 const cancel=entries.find(e=>e.kind==='native_confirmation_response_processed');assert.equal(cancel.body.state,'cancelled');assert.equal(cancel.body.source,'host_response');assert.equal(cancel.body.cause,'unknown');
 const safe=JSON.stringify({entries,logs:f.logs});
 for(const secret of [first.body.result.requestState,v.userRequest,v.patch.title])assert.equal(safe.includes(secret),false);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_requests').get().n,1);assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
});
test('timer continuation cannot change command, session, expected revision or originating tool',async t=>{
 const f=await fixture(t);await f.core.nativeCommands.setGrant({revision:2,capabilities:['timer.pause'],expiresAt:'2026-10-14T10:00:00.000Z'},f.d);
 f.sqlite.prepare("INSERT INTO sessions(id,title,status,started_at,active_since,elapsed_ms,updated_at,revision,last_command_id,provenance) VALUES(?,?,'running',?,?,0,?,7,?,'user')").run('isolated-existing-session','Isolated fixture','2026-10-13T10:00:00.000Z','2026-10-13T10:00:00.000Z','2026-10-13T10:00:00.000Z',uuid(170));
 const v={commandId:uuid(71),deviceId:f.d.id,action:'pause',sessionId:'isolated-existing-session',expectedRevision:7,occurredAt:'2026-10-13T10:00:00.000Z',expiresAt:'2026-10-13T11:00:00.000Z',userRequest:'Isolated pause request'};
 const first=await f.call('task_command',v),state=first.body.result.requestState;
 for(const change of [{commandId:uuid(72)},{sessionId:'other-session'},{expectedRevision:8}])assert.ok((await f.call('task_command',{...v,...change},reply(state))).body.error);
 assert.ok((await f.call('submit_native_command',{...v,version:1,kind:'timer'},reply(state))).body.error);
 assert.equal((await f.core.nativeCommands.status({commandId:v.commandId},'fixture-owner')).state,'awaiting_confirmation');
 const closed=await f.call('task_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
 assert.equal(closed.body.result.structuredContent.state,'cancelled');assert.equal(closed.body.result.structuredContent.request.expectedRevision,7);
 const trace=(await f.core.research.read({limit:100})).entries.find(e=>e.kind==='native_confirmation_prepared');assert.equal(trace.body.expectedRevision,7);assert.equal(trace.body.sessionId,v.sessionId);
 assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,1);
 assert.equal(f.sqlite.prepare('SELECT revision FROM sessions').get().revision,7);
});

test('host field diagnostics do not leak values and implicit expiry matches the stored request hash',async t=>{
 const f=await fixture(t),v=f.request(3900);delete v.expiresAt;
 const first=await f.call('submit_native_command',v),state=first.body.result.requestState;
 const rejected=await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'accept',content:{confirm:true,confirmed:'isolated-secret-value'},_meta:{credential:'isolated-secret-value'}}}});
 assert.ok(rejected.body.error);
 const log=await f.core.research.read({limit:100}),entry=log.entries.find(e=>e.kind==='native_confirmation_response_rejected');
 assert.equal(entry.body.stage,'response.content');assert.equal(entry.body.requestHash,entry.body.candidateRequestHash);
 assert.deepEqual(entry.body.responseShape.contentFields,[{name:'confirm',type:'boolean'},{name:'confirmed',type:'string'}]);
 assert.equal(JSON.stringify(log).includes('isolated-secret-value'),false);assert.equal(JSON.stringify(log).includes(state),false);
 const accepted=await f.call('submit_native_command',v,{requestState:state,inputResponses:{bc_native_confirmation:{action:'accept',content:{confirm:true},_meta:{credential:'isolated-secret-value'}}}});
 assert.equal(accepted.body.result.structuredContent.state,'queued');assert.equal(accepted.body.result.structuredContent.requestHash,entry.body.requestHash);
});

 test('default native entry completes without a host popup or secret and repeat cannot approve',async t=>{
  const f=await fixture(t,{confirmationChannel:'native'}),v=f.request(399);
  const first=await f.call('submit_native_command',v);
  assert.equal(first.body.result.resultType,'complete');
  assert.equal(first.body.result.structuredContent.state,'awaiting_confirmation');
  assert.equal(first.body.result.structuredContent.approvalUI.channel,'target_device_button');
  assert.equal(new Ajv({allowUnionTypes:true}).compile(confirmation.nativeCommandOutputSchema)(first.body.result.structuredContent),true);
  assert.equal(first.body.result._meta,undefined); assert.equal(first.body.result.requestState,undefined);
  const again=await f.call('submit_native_command',v);
  assert.equal(again.body.result.structuredContent.requestHash,first.body.result.structuredContent.requestHash);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM native_requests').get().n,1);
  assert.equal((await f.core.nativeCommands.pending({},f.d)).commands.length,0);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 });
 test('callback diagnostics correlate phases and identify rejected field without secret values',async t=>{
  const f=await fixture(t),v=f.request(398),first=await f.call('submit_native_command',v);
  const out=await f.call('submit_native_command',v,{requestState:first.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'accept',content:{confirm:true},extraField:'secret-value'}}});
  assert.ok(out.body.error);
  const rows=f.sqlite.prepare("SELECT body FROM research_log WHERE kind LIKE 'native_confirmation_response_%' ORDER BY id").all().map(r=>JSON.parse(r.body));
  assert.equal(rows.length,2);assert.equal(rows[0].callbackTraceId,rows[1].callbackTraceId);
  assert.equal(rows[1].stage,'response.envelope');assert.equal(rows[1].storedState,'awaiting_confirmation');
  assert.ok(rows[1].responseShape.envelopeFields.some(f=>f.name==='extraField'&&f.type==='string'));
  assert.equal(JSON.stringify(rows).includes('secret-value'),false);
 });

 test('one pending chat form is also actionable from target BC and late chat cancel cannot undo',async t=>{
  const f=await fixture(t),v=f.request(400),first=await f.call('submit_native_command',v);
  assert.equal(first.body.result.resultType,'input_required');
  const page=await f.core.nativeCommands.approvalList({},f.d);
  assert.equal(page.commands[0].commandId,v.commandId);
  const pending=page.commands[0];
  const accepted=await f.core.nativeCommands.decideFromDevice({commandId:v.commandId,requestHash:pending.requestHash,grantRevision:pending.grantRevision,expectedRevision:null,decision:'accept'},f.d);
  assert.equal(accepted.state,'queued');
  const late=await f.call('submit_native_command',v,{requestState:first.body.result.requestState,inputResponses:{bc_native_confirmation:{action:'cancel'}}});
  assert.equal(late.body.error.data.current.state,'queued');
  assert.equal(f.sqlite.prepare("SELECT COUNT(*) n FROM research_log WHERE kind='native_approval_decision'").get().n,1);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) n FROM sessions').get().n,0);
 });
