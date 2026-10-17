import {test} from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync,verify} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createAPNsProvider,APNsInputError} from '../lib/apns-provider.mjs';
import {createAPNsAttempt} from '../lib/apns-attempt.mjs';
const at=Date.parse('2026-10-17T00:00:00Z'),id='abcdabcd-abcd-4abc-8abc-000000000001';
const pair=generateKeyPairSync('ec',{namedCurve:'P-256'}),pem=pair.privateKey.export({type:'pkcs8',format:'pem'});
const credential={teamId:'ABCDE12345',keyId:'12345ABCDE',privateKey:pem};
const request=()=>({token:'ab'.repeat(96),environment:'production',apnsId:id,collapseId:'approval-fixture-device',expiresAt:new Date(at+86400000).toISOString(),kind:'alert',payload:{aps:{alert:{title:'ISOLATED fixture',body:'No real notification'},category:'fixture'},commandId:id}});
const response=(status=200,reason,extra={})=>new Response(reason?JSON.stringify({reason,...extra}):null,{status,headers:{'apns-id':id}});
const provider=fetcher=>createAPNsProvider({enabled:()=>true,credentials:()=>credential,fetcher,now:()=>at});

test('APNs is disabled by default without reading credentials or entering any network',async()=>{
 let credentials=0,network=0;const p=createAPNsProvider({credentials:()=>{credentials++;return credential;},fetcher:()=>{network++;throw Error('network forbidden');}});
 assert.deepEqual(await p.send(request()),{outcome:'not_sent',stage:'disabled'});assert.equal(credentials,0);assert.equal(network,0);
});
test('ephemeral test key produces verifiable ES256, fixed topic, deadline, collapse and no device/human success claim',async()=>{
 const calls=[];const p=provider(async(url,options)=>{calls.push({url,options});return response();});
 const a=await p.send(request()),b=await p.send({...request(),token:'ab'.repeat(12)});
 assert.equal(a.outcome,'provider_accepted');assert.equal(a.deviceReceived,'unknown');assert.equal(a.userSeen,'unknown');
 assert.equal(b.outcome,'provider_accepted');assert.equal(calls.length,2); // Token is opaque, not fixed32bytes.
 const {url,options}=calls[0];assert.equal(url,'https://api.push.apple.com/3/device/'+request().token);
 assert.equal(options.redirect,'error');assert.equal(options.headers['apns-topic'],'com.jason.BetterCalendar');
 assert.equal(options.headers['apns-expiration'],String((at+86400000)/1000));assert.equal(options.headers['apns-collapse-id'],request().collapseId);
 assert.equal(options.headers['apns-push-type'],'alert');assert.equal(options.headers['apns-priority'],'10');
 const jwt=options.headers.authorization.slice(7),parts=jwt.split('.');
 assert.equal(verify('sha256',Buffer.from(parts[0]+'.'+parts[1]),{key:pair.publicKey,dsaEncoding:'ieee-p1363'},Buffer.from(parts[2],'base64url')),true);
 assert.deepEqual(JSON.parse(Buffer.from(parts[1],'base64url')),{iss:credential.teamId,iat:at/1000});
 assert.equal(calls[1].options.headers.authorization,options.headers.authorization);
 assert.ok(!JSON.stringify(a).includes(request().token)&&!JSON.stringify(a).includes(jwt)&&!JSON.stringify(a).includes(pem));
});
test('invalid destinations, byte oversize, deadlines and mislabeled background alerts fail before any network',async()=>{
 let sent=0;const p=provider(()=>{sent++;return response();});
 for(const patch of [{environment:'https://other.invalid'},{token:'?credential=private'},{collapseId:'汉'.repeat(22)},{expiresAt:new Date(at).toISOString()},{payload:{aps:{alert:'汉'.repeat(1500)}}},{kind:'background'}])await assert.rejects(p.send({...request(),...patch}),APNsInputError);
 const receipt=await p.send({...request(),kind:'background',payload:{aps:{'content-available':1},commandId:id}});
 assert.equal(receipt.outcome,'provider_accepted');assert.equal(sent,1);
});
test('known rejection is distinct from a timeout, missing identity or arbitrary provider text',async()=>{
 const bad=await provider(()=>response(410,'Unregistered',{timestamp:at-1000})).send(request());
 assert.equal(bad.outcome,'rejected');assert.equal(bad.tokenInvalidatedAt,at-1000);assert.equal(bad.retryable,false);
 const retry=await provider(()=>response(503,'ServiceUnavailable')).send(request());assert.equal(retry.retryable,true);
 const unknown=await provider(()=>{throw Error(request().token+' '+pem);}).send(request());assert.deepEqual(unknown,{outcome:'unknown',stage:'transport',apnsId:id,userSeen:'unknown'});
 const wrong=await provider(()=>new Response(null,{status:200})).send(request());assert.equal(wrong.outcome,'unknown');
 const raw=await provider(()=>response(500,'private-user-content')).send(request());assert.equal(raw.outcome,'unknown');assert.ok(!JSON.stringify(raw).includes('private-user-content'));
});

function fixture(t){
 const dir=mkdtempSync(join(tmpdir(),'bc-apns-offline-')),path=join(dir,'outbox.sqlite');let db;
 const open=()=>{db=new DatabaseSync(path);db.exec('CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,revision INTEGER,phase TEXT,body TEXT,result TEXT)');};open();
 t.after(()=>{db.close();rmSync(dir,{recursive:true,force:true});});
 const job={id,revision:1,phase:'ready',commandId:id,deviceId:'isolated-fixture-device',tokenVersion:1,requestHash:'a'.repeat(64),grantRevision:1,reviewerRevision:2,expectedRevision:'b'.repeat(64),request:request()};
 db.prepare('INSERT INTO jobs VALUES(?,?,?,?,NULL)').run(id,1,'ready',JSON.stringify(job));
 let finishFails=false,claimFails=false;
 const store={
  async get(key){const r=db.prepare('SELECT * FROM jobs WHERE id=?').get(key);return r?{...JSON.parse(r.body),revision:r.revision,phase:r.phase,result:r.result?JSON.parse(r.result):null}:null;},
  async claim(key,rev){if(claimFails)throw Error('isolated persistence failure');return db.prepare("UPDATE jobs SET revision=revision+1,phase='reserved' WHERE id=? AND revision=? AND phase='ready'").run(key,rev).changes>0;},
  async finish(key,rev,phase,result){if(finishFails)throw Error('isolated persistence failure');return db.prepare("UPDATE jobs SET revision=revision+1,phase=?,result=? WHERE id=? AND revision=? AND phase='reserved'").run(phase,JSON.stringify(result),key,rev).changes>0;}
 };
 const authorized=()=>({allowed:true,state:'awaiting_confirmation',commandId:job.commandId,deviceId:job.deviceId,tokenVersion:job.tokenVersion,requestHash:job.requestHash,grantRevision:job.grantRevision,reviewerRevision:job.reviewerRevision,expectedRevision:job.expectedRevision,expiresAt:job.request.expiresAt});
 return {store,job,authorized,reopen(){db.close();open();},failFinish(){finishFails=true;},failClaim(){claimFails=true;}};
}
test('two isolated dispatchers reserve once and restart reads the same accepted receipt without a resend',async t=>{
 const f=fixture(t);let sent=0;const options={store:f.store,authorize:f.authorized,now:()=>at,provider:{send:async v=>{sent++;assert.equal(v.apnsId,id);return {outcome:'provider_accepted',apnsId:id,deviceReceived:'unknown'};}}};
 await Promise.all([createAPNsAttempt(options)(id),createAPNsAttempt(options)(id)]);assert.equal(sent,1);
 f.reopen();assert.equal((await createAPNsAttempt(options)(id)).outcome,'provider_accepted');assert.equal(sent,1);
});
test('a provider acceptance followed by receipt persistence failure remains unknown after an actual store reopen',async t=>{
 const f=fixture(t);let sent=0;f.failFinish();const options={store:f.store,authorize:f.authorized,now:()=>at,provider:{send:async()=>{sent++;return {outcome:'provider_accepted',apnsId:id};}}};
 assert.equal((await createAPNsAttempt(options)(id)).stage,'receipt_not_persisted');f.reopen();
 assert.equal((await createAPNsAttempt(options)(id)).outcome,'unknown');assert.equal(sent,1);
});
test('claim persistence failure prevents provider entry; revocation after reservation also prevents it',async t=>{
 const f=fixture(t);let sent=0;const options={store:f.store,authorize:f.authorized,now:()=>at,provider:{send:async()=>{sent++;return {outcome:'provider_accepted',apnsId:id};}}};
 f.failClaim();assert.equal((await createAPNsAttempt(options)(id)).stage,'reservation_not_confirmed');assert.equal(sent,0);
 const g=fixture(t);let reads=0;
 const result=await createAPNsAttempt({...options,store:g.store,authorize:()=>++reads===1?g.authorized():{...g.authorized(),allowed:false}})(id);
 assert.equal(result.stage,'closed_or_revoked_after_claim');assert.equal(sent,0);
});
test('binding, expectedRevision and expiry mismatches never enter the provider; arbitrary thrown provider failures are unknown',async t=>{
 const f=fixture(t);let sent=0;const options={store:f.store,authorize:f.authorized,now:()=>at,provider:{send:async()=>{sent++;throw Error('unknown failure after possible send');}}};
 for(const patch of [{requestHash:'different'},{deviceId:'different-device'},{tokenVersion:2},{grantRevision:9},{reviewerRevision:9},{expectedRevision:'different'},{expiresAt:new Date(at-1).toISOString()}]){
  const r=await createAPNsAttempt({...options,authorize:()=>({...f.authorized(),...patch})})(id);assert.equal(r.outcome,'not_sent');
 }assert.equal(sent,0);
 const incomplete={...options,store:{...f.store,get:async()=>({...f.job,deviceId:undefined})}};
 assert.equal((await createAPNsAttempt(incomplete)(id)).stage,'invalid_job_binding');assert.equal(sent,0);
 assert.equal((await createAPNsAttempt(options)(id)).outcome,'unknown');assert.equal(sent,1);
 f.reopen();assert.equal((await createAPNsAttempt(options)(id)).outcome,'unknown');assert.equal(sent,1);
});
