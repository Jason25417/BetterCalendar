import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,rmSync,readFileSync,statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Recorder,redact,comparisonInputs } from './research-recorder.mjs';

const now=new Date('2026-10-12T20:00:30Z'),minute=Math.floor(now.getTime()/60000);
function setup(t,config={}) {
 const root=mkdtempSync(join(tmpdir(),'bc-research-test-'));t.after(()=>rmSync(root,{recursive:true,force:true}));return new Recorder(root,{clock:()=>now,config});
}
const change=(id,source='bc:tasks')=>({id,sourceKey:source,occurredAt:now.toISOString(),observation:{eventId:`event-${id}`,source,assertion:'observed',value:{title:'fixture',n:id},observedAt:now.toISOString(),receivedAt:now.toISOString()}});
function client(options={}) {
 let failed=false;const requests=[];
 const fetcher=async(path,args)=>{
   requests.push({path,args});
   if(options.failOnce&&path==='research/changes'&&!failed){failed=true;throw Error('offline');}
   if(path==='research/batches')return {entries:args.afterMinute<minute?[{id:`minute_${minute}`,minute,createdAt:now.toISOString(),processedAt:null,event:{data:{fromChangeId:1,throughChangeId:3,decision:{policy:'ForwardAllToDots',forward:true}}}}]:[],nextCursor:minute,throughMinute:minute,hasMore:false};
   if(path==='research/changes')return args.afterId===0?{changes:[change(1),change(2,'calendar.events')],nextCursor:2,hasMore:true}:{changes:[change(3,'mac.activity')],nextCursor:3,hasMore:false};
   if(path==='research/state')return {readAt:now.toISOString(),coverage:[{deviceId:'phone',sources:[{source:'ios.app',availability:'not_received'}]}],sources:[],sessions:[]};
   if(path==='research/log')return {entries:[],nextCursor:0,throughId:0,hasMore:false};
   throw Error('unexpected endpoint');
 };return {fetcher,requests};
}
test('complete immutable local snapshots survive restart; replay compares same window with zero network',async t=>{
 const r=setup(t),c=client();await r.tick(c.fetcher);assert.equal(r.db.prepare('SELECT COUNT(*) n FROM runs').get().n,1);
 const before=c.requests.length,replay=r.replay(`minute_${minute}`);assert.equal(c.requests.length,before);assert.equal(replay.sideEffects,false);assert.equal(replay.network,false);
 assert.deepEqual(replay.groups.map(g=>g.changes.length),[1,3,3]);assert.deepEqual(replay.groups[0].window,replay.groups[2].window);assert.equal(replay.evaluation.usefulness,null);
 const root=r.root;r.db.close();const reopened=new Recorder(root,{clock:()=>now});t.after(()=>reopened.db.close());await reopened.tick(c.fetcher);assert.equal(reopened.db.prepare('SELECT COUNT(*) n FROM runs').get().n,1);
 assert.equal(statSync(join(root,'research.sqlite')).mode&0o777,0o600);
});
test('disconnect does not advance cursor; retry reads complete batch rather than inventing success',async t=>{
 const r=setup(t),c=client({failOnce:true});t.after(()=>r.db.close());await assert.rejects(r.tick(c.fetcher),/offline/);
 assert.equal(r.get('minuteCursor'),null);assert.equal(r.db.prepare('SELECT COUNT(*) n FROM failures').get().n,1);
 await r.tick(c.fetcher);assert.equal(r.get('minuteCursor'),minute);
 assert.equal(c.requests.filter(q=>q.path==='research/changes'&&q.args.afterId===0).length,2);
});
test('capacity stops without advancing state; local API rejects writers; export excludes secrets',async t=>{
 const r=setup(t,{maxBytes:10000});t.after(()=>r.db.close());const c=client();await assert.rejects(r.tick(c.fetcher),/capacity/);assert.equal(r.get('minuteCursor'),null);
 await assert.rejects(r.call(c.fetcher,'tasks/command',{action:'start'}),/rejects side effects/);
 const cleaned=redact({token:'very-secret',text:'Bearer abcd whsec_123456 sk-123456789012',nested:{password:'x'},normal:'original note'},['very-secret']);
 assert.equal(cleaned.normal,'original note');assert.ok(!JSON.stringify(cleaned).includes('very-secret'));assert.ok(!JSON.stringify(cleaned).includes('whsec_'));
});
test('viewer is offline escaped HTML; export contains raw referenced snapshots and explicit gaps',async t=>{
 const r=setup(t),c=client();t.after(()=>r.db.close());await r.tick(c.fetcher);
 const page=readFileSync(r.view(),'utf8');assert.ok(page.includes("default-src 'none'"));assert.ok(page.includes('尚无完整研究回执'));assert.ok(!page.includes('<script'));
 const file=join(r.root,'export.json');r.export(file);const exported=JSON.parse(readFileSync(file));assert.equal(exported.version,1);assert.ok(exported.snapshots.length>=4);assert.equal(exported.runs[0].attention.userFeedback,'unknown');
 assert.throws(()=>r.export(file),/exists/);
});
test('minimal capability contrast retains user statements and does not equate absent habits to value',()=>{
 const c=[change(1),change(2,'calendar.events'),{...change(3,'habit'),observation:{source:'habit',assertion:'inferred',value:'fixture'}}];
 const groups=comparisonInputs(c,{from:'fixed',throughChangeId:3});assert.deepEqual(groups.map(g=>g.changes.length),[1,2,3]);assert.ok(groups[2].reasoning.includes('not proof'));
});
test('retention keeps referenced request snapshots and does not delete fresh evidence',async t=>{
 const r=setup(t,{retentionDays:1}),c=client();t.after(()=>r.db.close());await r.tick(c.fetcher);const count=r.db.prepare('SELECT COUNT(*) n FROM snapshots').get().n;r.prune();assert.equal(r.db.prepare('SELECT COUNT(*) n FROM snapshots').get().n,count);assert.equal(r.db.prepare('SELECT COUNT(*) n FROM runs').get().n,1);
});


test('research summary separates processed silence, missing results and shadow savings without counting corrections twice',async t=>{
 const r=setup(t),c=client();t.after(()=>r.db.close());await r.tick(c.fetcher);
 const run=JSON.parse(r.db.prepare('SELECT body FROM runs').get().body);
 const second={...run,id:'second',shadow:{...run.shadow,wake:false}};
 r.db.prepare('INSERT INTO runs VALUES(?,?)').run(second.id,JSON.stringify(second));
 const initial=r.stats();assert.equal(initial.awaitingResearchResult,2);assert.equal(initial.processedWithoutAction,0);assert.equal(initial.shadowWouldSkipWake,1);
 const result={id:1,callId:'result_1',batchId:run.id,kind:'batch_result',createdAt:new Date(now.getTime()+3000).toISOString(),body:{notification:{channel:'silent',result:'not_requested'},operation:{kind:'none'},supersedes:null}};
 r.db.prepare('INSERT INTO calls VALUES(?,?)').run(1,JSON.stringify(result));
 const corrected={...result,id:2,callId:'result_2',createdAt:new Date(now.getTime()+70000).toISOString(),body:{...result.body,supersedes:'result_1'}};
 r.db.prepare('INSERT INTO calls VALUES(?,?)').run(2,JSON.stringify(corrected));
 const summary=r.stats();assert.equal(summary.recordedAgentResults,1);assert.equal(summary.awaitingResearchResult,1);assert.equal(summary.processedWithoutAction,1);assert.equal(summary.processedWithoutActionAndShadowWouldSkip,0);assert.equal(summary.correctionCount,1);assert.equal(summary.batches[0].resultId,'result_2');assert.equal(summary.batches[0].firstResultDelaySeconds,3);assert.equal(summary.batches[0].latestResultDelaySeconds,70);assert.equal(summary.batches[1].firstResultDelaySeconds,null);assert.equal(summary.modelCost,null);assert.equal(summary.userApproval,'unknown');
 assert.ok(readFileSync(r.view(),'utf8').includes('真实 ForwardAll 仍运行'));
 const file=join(r.root,'summary-export.json');r.export(file);assert.equal(JSON.parse(readFileSync(file)).summary.recordedAgentResults,1);
 const command={...result,id:3,callId:'result_3',batchId:'second',body:{notification:{channel:'chat',result:'reported_sent'},operation:{kind:'task_command',commandId:'command_1'},supersedes:null}};
 r.db.prepare('INSERT INTO calls VALUES(?,?)').run(3,JSON.stringify(command));
 assert.equal(r.stats().notificationReportedSent,1);assert.equal(r.stats().operationReceipts,1);assert.equal(r.stats().processedWithoutAction,1);
});
