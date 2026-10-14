import {test} from 'node:test';
import assert from 'node:assert/strict';
import {confirmationPresentation} from '../lib/confirmation-presentation.mjs';
import {nativeFormParameters} from '../lib/native-form-confirmation.mjs';
const value={commandId:'518db08f-af21-4c4f-99be-56d70d7d73c2',deviceId:'fixture-mac',state:'cancelled',expiresAt:'2026-10-14T03:03:25.000Z',request:{kind:'item',action:'update',recordId:'fixture-record',expectedRevision:'a'.repeat(64),patch:{note:'BC 接入验收（临时备注）'},userRequest:'agent-reported text'}};
const record={id:'fixture-record',revision:'a'.repeat(64),values:{title:'整理5529笔记',note:''}};
const page={complete:true,records:[record],hasMore:false,snapshotEventId:'fixture-snapshot',observedAt:'2026-10-14T02:48:00.000Z',receivedAt:'2026-10-14T02:48:01.000Z',freshness:'current'};
function fixture(read=async()=>page){return {nativeCommands:{capabilities:async()=>({devices:[{deviceId:'fixture-mac',label:'Jason Mac'}]})},readPoolRecords:read};}
test('item confirmation resolves device label and exact before-values without trusting agent prose',async()=>{
 const display=await confirmationPresentation(fixture(),value),params=nativeFormParameters(value,display);
 assert.equal(display.recordTitle,'整理5529笔记');assert.deepEqual(display.before,{note:''});
 const text=params.requestedSchema.properties.confirm.description;
 for(const expected of ['整理5529笔记','Jason Mac','（空白） → BC 接入验收（临时备注）'])assert.ok(text.includes(expected));
 for(const hidden of [value.deviceId,value.commandId,value.request.expectedRevision,value.request.userRequest])assert.equal(text.includes(hidden),false);
 assert.equal(params.requestedSchema.properties.confirm.default,false);
 assert.equal(display.source.snapshotEventId,'fixture-snapshot');assert.match(display.source.beforeHash,/^[a-f0-9]{64}$/);
});
test('before-values are pinned across pagination rather than mixing later snapshots',async()=>{
 const calls=[];const core=fixture(async input=>{calls.push(input);return calls.length===1?{...page,records:[],hasMore:true,nextCursor:'server-pinned-cursor'}:page;});
 assert.equal((await confirmationPresentation(core,value)).before.note,'');
 assert.equal(calls[1].cursor,'server-pinned-cursor');assert.equal(calls[1].deviceId,value.deviceId);
});
test('missing data, mismatched revision, unread field and broken pagination fail before publishing',async()=>{
 for(const broken of [{...page,complete:false},{...page,records:[]},{...page,records:[{...record,revision:'b'.repeat(64)}]},{...page,records:[{...record,values:{title:'fixture'}}]},{...page,records:[],hasMore:true,nextCursor:null}])await assert.rejects(confirmationPresentation(fixture(async()=>broken),value),/确认内容加载失败/);
});
test('stale matching source is labeled and full changed text remains plain text',async()=>{
 const body='<script>fixture</script>\n'.repeat(100),changed={...value,request:{...value.request,patch:{note:body}}};
 const display=await confirmationPresentation(fixture(async()=>({...page,freshness:'stale'})),changed);
 const params=nativeFormParameters(changed,display,{preview:true});
 assert.ok(params.requestedSchema.properties.confirm.description.includes(body));assert.match(params.requestedSchema.properties.confirm.description,/旧快照/);
 assert.match(params.requestedSchema.properties.confirm.description,/原请求仍是 cancelled/);assert.match(params.requestedSchema.properties.confirm.title,/不会执行/);
});
