import { createHash } from 'node:crypto';
const digest=v=>createHash('sha256').update(JSON.stringify(v)).digest('hex');
const classes=['bc_native','connector','user_statement','public','habit','inference'];
const time=v=>typeof v==='string'&&/(Z|[+-]\d\d:\d\d)$/.test(v)&&Number.isFinite(Date.parse(v));
const finite=v=>Number.isFinite(v)&&v>=0;

// Import a real supplied record. This does not run a connector or a model, and
// never upgrades a transcript to independently observed execution evidence.
export function validateEvidence(value,run,inputs) {
  if(value.version!==1||typeof value.id!=='string'||!value.id.length||value.id.length>150||!time(value.occurredAt))throw Error('invalid evidence identity/version/time');
  if(!run||value.runId!==run.id)throw Error('unknown evidence run');
  const v={...value,evidenceLevel:'supplied_record_not_independently_executed',imported:true};
  if(value.kind==='external_call') {
    if(typeof value.tool!=='string'||!value.tool.length||!classes.includes(value.sourceClass)||!time(value.startedAt)||!time(value.returnedAt)||Date.parse(value.returnedAt)<Date.parse(value.startedAt)||!['returned','failed'].includes(value.result)||value.arguments===undefined||value.response===undefined)throw Error('incomplete external call record');
    if(value.kind==='external_call'&&(!value.pagination||typeof value.pagination.complete!=='boolean'||typeof value.pagination.hasMore!=='boolean'||value.pagination.complete&&value.pagination.hasMore))throw Error('missing or conflicting pagination evidence');
  } else if(value.kind==='model_usage') {
    if(typeof value.model!=='string'||!value.model||typeof value.callRef!=='string'||!value.callRef||!value.usage||!['provider_response','user_report'].includes(value.reportSource))throw Error('incomplete usage report');
    for(const key of ['input','output','cachedInput'])if(value.usage[key]!=null&&(!Number.isSafeInteger(value.usage[key])||value.usage[key]<0))throw Error('invalid token count');
    if(value.usage.cost!=null&&(!finite(value.usage.cost)||!/^\w{3}$/.test(value.usage.currency??'')))throw Error('invalid actual cost/currency');
    v.costIsEstimate=false; // Never invent cost from a model name or price table.
  } else if(value.kind==='user_feedback') {
    if(value.reportSource!=='user_statement'||!['helpful','unhelpful','mixed','unknown'].includes(value.usefulness)||value.attentionSeconds!=null&&!finite(value.attentionSeconds)||typeof value.statement!=='string'||!value.statement)throw Error('feedback must include an explicit user statement');
    v.evidenceLevel='explicit_user_report_not_inferred_from_silence';
  } else if(value.kind==='replay_result') {
    const input=inputs.find(i=>i.group===value.group);
    if(!input||value.inputHash!==digest(input)||typeof value.model!=='string'||!value.model||value.output===undefined)throw Error('replay result does not match archived input');
    v.execution='imported_output_only';v.sideEffects=false;v.network=false;
  } else throw Error('unknown evidence kind');
  return v;
}

export function comparisonPack(replay,records=[]) {
  const groups=replay.groups.map(g=>({group:g.group,input:g,inputHash:digest(g),results:records.filter(r=>r.kind==='replay_result'&&r.group===g.group&&r.inputHash===digest(g))}));
  const models=[...new Set(groups.flatMap(g=>g.results.map(r=>r.model)))];
  return {version:1,runId:replay.id,network:false,sideEffects:false,groups,
    sameModelComplete:models.length===1&&groups.every(g=>g.results.length===1),
    commonModel:models.length===1?models[0]:null,quality:'unrated',
    interpretation:'固定输入与导入输出可对照；不调用模型、不发送通知或操作计时。未导入的组保持缺失，输入差异不是收益证明。'};
}
