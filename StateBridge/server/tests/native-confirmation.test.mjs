import {test} from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {nativeToolResult,nativeConfirmationHtml} from '../lib/native-confirmation.mjs';
test('confirmation secret is outside model content; widget only invokes approval on click',async()=>{
 const approval={commandId:'id',requestHash:'hash',token:'private-widget-fixture'};
 const value={nativeCommandId:'id',deviceId:'fixture',requestHash:'hash',state:'awaiting_confirmation',expiresAt:'2026-10-14T10:00:00Z',request:{kind:'item',action:'update',userRequest:'fixture',patch:{title:'<script>malicious text</script>'}}};
 const result=nativeToolResult(value,approval);
 assert.equal(result.resultType,'complete');
 assert.equal(JSON.stringify({content:result.content,structuredContent:result.structuredContent}).includes(approval.token),false);
 const elements=new Map(),calls=[];const element=id=>{if(!elements.has(id))elements.set(id,{disabled:true,textContent:''});return elements.get(id);};
 const window={openai:{toolOutput:value,toolResponseMetadata:{mcp_tool_result:result},callTool:async(name,args)=>{calls.push({name,args});return nativeToolResult({...value,state:'queued'});}},addEventListener(){},parent:{postMessage(){throw Error('unnecessary network');}}};
 const code=nativeConfirmationHtml.match(/<script>([\s\S]*)<\/script>/)[1];
 vm.runInNewContext(code,{window,document:{getElementById:element},setTimeout,clearTimeout,Date,Map,JSON,Error});
 assert.equal(calls.length,0);assert.equal(element('approve').disabled,false);assert.match(element('details').textContent,/<script>/);assert.equal('innerHTML' in element('details'),false);
 await element('approve').onclick();assert.equal(calls.length,1);assert.equal(calls[0].name,'approve_native_command');assert.equal(calls[0].args.token,approval.token);assert.equal(element('approve').disabled,true);assert.match(element('status').textContent,/等待指定设备/);
});
test('widget lacking hidden confirmation data cannot approve',()=>{
 const elements=new Map();const window={openai:{toolOutput:{nativeCommandId:'id',requestHash:'hash',state:'awaiting_confirmation',expiresAt:'2026-10-14T10:00:00Z',request:{}},toolResponseMetadata:{},callTool(){throw Error('not human approved');}},addEventListener(){}};
 vm.runInNewContext(nativeConfirmationHtml.match(/<script>([\s\S]*)<\/script>/)[1],{window,document:{getElementById(id){if(!elements.has(id))elements.set(id,{disabled:true});return elements.get(id);}},Date,Map,JSON,Error});
 assert.equal(elements.get('approve').disabled,true);
});
test('standard MCP Apps bridge receives hidden meta and waits for an actual click',async()=>{
 const elements=new Map(),listeners=[],messages=[];
 const parent={postMessage(message){messages.push(message);}};
 const window={parent,addEventListener(name,listener){if(name==='message')listeners.push(listener);}};
 const element=id=>{if(!elements.has(id))elements.set(id,{disabled:true});return elements.get(id);};
 vm.runInNewContext(nativeConfirmationHtml.match(/<script>([\s\S]*)<\/script>/)[1],{window,document:{getElementById:element},setTimeout,clearTimeout,Date,Map,JSON,Error});
 const initialize=messages[0];assert.equal(initialize.method,'ui/initialize');
 const send=data=>listeners.forEach(listener=>listener({source:parent,data}));
 send({jsonrpc:'2.0',id:initialize.id,result:{}});await new Promise(resolve=>setImmediate(resolve));
 const approval={commandId:'id',requestHash:'hash',token:'standard-widget-only'};
 send({jsonrpc:'2.0',method:'ui/notifications/tool-result',params:{structuredContent:{nativeCommandId:'id',requestHash:'hash',state:'awaiting_confirmation',expiresAt:'2026-10-14T10:00:00Z',request:{}},_meta:{approval}}});
 assert.equal(element('approve').disabled,false);assert.equal(messages.some(m=>m.method==='tools/call'),false);
 const clicked=element('approve').onclick();const call=messages.at(-1);assert.equal(call.method,'tools/call');assert.deepEqual(JSON.parse(JSON.stringify(call.params.arguments)),approval);
 send({jsonrpc:'2.0',id:call.id,result:nativeToolResult({nativeCommandId:'id',requestHash:'hash',state:'queued',expiresAt:'2026-10-14T10:00:00Z',request:{}})});await clicked;assert.equal(element('approve').disabled,true);
});
