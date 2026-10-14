import {test} from 'node:test';
import assert from 'node:assert/strict';
import {normalizeFormResponse,formResponseShape} from '../lib/native-form-response.mjs';
test('known complete result metadata is non-authoritative and never becomes a form field',()=>{
 const response={action:'accept',content:{confirm:true},resultType:'complete',_meta:{token:'isolated-secret',userConfirmed:true,patch:{title:'ignored'}}};
 assert.deepEqual(normalizeFormResponse(response),{action:'accept',content:{confirm:true}});
 assert.equal(JSON.stringify(formResponseShape(response)).includes('isolated-secret'),false);
 assert.deepEqual(formResponseShape(response).presentFields,['action','content','resultType','_meta']);
});
test('metadata alone, truthy coercion, unsupported discriminants and extra content cannot approve',()=>{
 for(const v of [{action:'accept',_meta:{confirm:true}},{action:'accept',content:{confirm:'true'}},{action:'accept',content:{confirm:1}},
  {action:'accept',content:{confirm:true},resultType:'input_required'},{action:'accept',content:{confirm:true},_meta:'invalid'},
  {action:'accept',content:{confirm:true,patch:{note:'bad'}}},{action:'accept',content:{confirm:true},userConfirmed:true}])assert.throws(()=>normalizeFormResponse(v));
});
test('cancel can contain null content but never an affirmative content object',()=>{
 assert.deepEqual(normalizeFormResponse({action:'cancel',content:null,resultType:'complete'}),{action:'cancel'});
 assert.deepEqual(normalizeFormResponse({action:'cancel',content:{},_meta:{fixture:'ignored'}}),{action:'cancel'});
 assert.throws(()=>normalizeFormResponse({action:'cancel',content:{confirm:true}}));
});
test('validation diagnostics name fields, types and missing fields without response or metadata values',()=>{
 const v={action:'isolated-value-never-log',content:{confirmed:'isolated-value-never-log'},_meta:{token:'isolated-secret-never-log'},extraField:'isolated-extra-never-log'};
 const d=formResponseShape(v);
 assert.deepEqual(d.contentFields,[{name:'confirmed',type:'string'}]);assert.deepEqual(d.missingContentFields,['confirm']);
 assert.ok(d.envelopeFields.some(f=>f.name==='extraField'&&f.type==='string'));
 assert.equal(JSON.stringify(d).includes('never-log'),false);assert.equal(JSON.stringify(d).includes('token'),false);
 assert.throws(()=>normalizeFormResponse(v),e=>e.confirmationStage==='response.envelope');
 assert.throws(()=>normalizeFormResponse({action:'accept',content:{confirmed:true}}),e=>e.confirmationStage==='response.content');
});
test('diagnostic variants remain explicit and do not widen real command confirmation',()=>{
 assert.deepEqual(normalizeFormResponse({action:'accept',content:{confirm:'确认显示测试'}},'choice').content,{confirm:'确认显示测试'});
 assert.throws(()=>normalizeFormResponse({action:'accept',content:{confirm:'确认显示测试'}}));
 assert.deepEqual(normalizeFormResponse({action:'accept',content:{confirm:false,review:'plain fixture'}},'review').content,{confirm:false,review:'plain fixture'});
 assert.throws(()=>normalizeFormResponse({action:'accept',content:{confirm:true,review:'fixture'}}));
});
