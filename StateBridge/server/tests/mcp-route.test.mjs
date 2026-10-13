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
const ts=createRequire(import.meta.url)('typescript');
const Ajv=createRequire(import.meta.url)('ajv');
const routeSource=ts.transpileModule(readFileSync(new URL('../app/mcp/route.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const meta={'io.modelcontextprotocol/protocolVersion':'2026-07-28','io.modelcontextprotocol/clientCapabilities':{elicitation:{}}};
const uuid=n=>`12345678-1234-4234-8234-${String(n).padStart(12,'0')}`;
async function fixture(t,{fetcher=()=>{throw Error('test forbids network');}}={}){
 const sqlite=new DatabaseSync(':memory:');t.after(()=>sqlite.close());
 for(const file of readdirSync(new URL('../drizzle/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(readFileSync(new URL('../drizzle/'+file,import.meta.url),'utf8'));
 let failReturned=false,now=new Date('2026-10-13T10:00:00.000Z');
 const prepare=sql=>{let args=[];return {bind(...v){args=v;return this;},first(){return sqlite.prepare(sql).get(...args)??null;},all(){return {results:sqlite.prepare(sql).all(...args)};},run(){if(failReturned&&sql.startsWith('INSERT INTO research_log')&&args[1]==='call_returned'){failReturned=false;throw Error('isolated persistence failure');}return sqlite.prepare(sql).run(...args);}};};
 const db={prepare,batch(ops){sqlite.exec('BEGIN');try{const out=ops.map(op=>op.run());sqlite.exec('COMMIT');return out;}catch(e){sqlite.exec('ROLLBACK');throw e;}}};
 const reopen=()=>bridge.createBridge(db,{now:()=>now,fetcher});
 let core=reopen();const logs=[];
 const modules={'@/lib/service':{service:()=>core},'@/lib/bridge.mjs':bridge,'@/lib/dot-instructions':{dotInstructions:'isolated route fixture'},'@/lib/native-confirmation.mjs':confirmation,'@/lib/native-commands.mjs':commands,'@/lib/mcp-client-capabilities.mjs':capabilities,'@/lib/native-form-confirmation.mjs':form};
 const exports={};vm.runInNewContext(routeSource,{exports,require(name){assert.ok(modules[name],`unexpected import ${name}`);return modules[name];},Response,TextEncoder,console:{info(...args){logs.push(args);},warn(...args){logs.push(args);}}});
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
 return {sqlite,logs,d,request,rpc,call,get core(){return core;},restart(){core=reopen();},failResult(){failReturned=true;},advance(ms){now=new Date(now.getTime()+ms);}};
}
const reply=state=>({requestState:state,inputResponses:{bc_native_confirmation:{action:'accept',content:{confirm:true}}}});
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
 assert.equal(trace[1].body.arguments.confirmation.transport,'mcp_form');assert.equal(trace[1].body.arguments.confirmation.confirmed,true);
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
 assert.deepEqual(JSON.parse(JSON.stringify(call.body.arguments.confirmation)),{transport:'mcp_form',action:'cancel',confirmed:false,source:'host_response',userGesture:'unknown',cause:'unknown'});
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
