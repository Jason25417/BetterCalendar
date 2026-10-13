import {test} from 'node:test';
import assert from 'node:assert/strict';
import {clientConfirmationCapabilities as inspect} from '../lib/mcp-client-capabilities.mjs';
const params = capabilities => ({_meta:{'io.modelcontextprotocol/protocolVersion':'2026-07-28','io.modelcontextprotocol/clientCapabilities':capabilities}});
test('missing and malformed metadata remain unknown, not unsupported',()=>{
  assert.equal(inspect().form,'unknown');
  for(const bad of [null,[],false,'not metadata'])assert.equal(inspect(params(bad)).capabilities,'malformed');
  assert.equal(inspect({_meta:'bad'}).protocolVersion,'unknown');
});
test('explicit and standard implicit form declarations are distinguished',()=>{
  assert.equal(inspect(params({elicitation:{form:{}}})).form,'declared_explicit');
  assert.equal(inspect(params({elicitation:{}})).form,'declared_implicit');
  for(const caps of [{},{elicitation:{url:{}}},{elicitation:{form:false}},{elicitation:[]}])assert.equal(inspect(params(caps)).form,'not_declared');
});
test('UI declaration does not imply actual rendering or human approval',()=>{
  const value=inspect(params({extensions:{'io.modelcontextprotocol/ui':{mimeTypes:['text/html;profile=mcp-app']}}}));
  assert.equal(value.ui,'declared');assert.equal(value.rendering,'unverified');assert.equal(value.humanConfirmation,'unverified');
});
test('only safe classification survives; arbitrary private metadata is excluded',()=>{
  const p=params({elicitation:{form:{token:'private-fixture'}},extensions:{'private.example/secret':{credential:'secret-fixture'}}});
  p._meta['io.modelcontextprotocol/clientInfo']={name:'private-client'};
  p._meta['io.modelcontextprotocol/protocolVersion']='Bearer private-fixture';
  const value=inspect(p);assert.equal(value.protocolVersion,'unknown');
  assert.doesNotMatch(JSON.stringify(value),/private-fixture|secret-fixture|private-client|credential/);
});
