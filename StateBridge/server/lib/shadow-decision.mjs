import { canonical } from './bridge.mjs';

// Pure: receives frozen evidence and cannot import a sender, timer or writer.
const refreshKeys=new Set(['readAt','sampledAt','capturedAt','updatedAt','lastReadAt','observedAt','receivedAt','sequence']);
export const SHADOW_VERSION=2;
function substantive(value) {
  if(Array.isArray(value))return value.map(substantive);
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).filter(([k])=>!refreshKeys.has(k)).map(([k,v])=>[k,substantive(v)]));
  return value;
}
export function shadowDecision(changes,prior={}) {
  const seen=new Set(),next={...prior},reasons=[];let meaningful=0;
  for(const c of changes) {
    const o=c.observation ?? {},key=c.sourceKey,id=o.eventId ?? c.id;
    if(seen.has(id)){reasons.push({id,reason:'duplicate_event'});continue;}seen.add(id);
    const source=o.source ?? key?.split(':').at(-1);
    const onlineHeartbeat=source==='device.status'&&o.value?.availability==='online';
    // Do not suppress errors, staleness, timing commands or user intent.
    if(o.assertion==='user'||key==='bc:tasks'||o.freshness==='stale'||o.value?.availability&&!onlineHeartbeat&&!['available','partial','not-frontmost'].includes(o.value.availability)) {
      meaningful++;reasons.push({id,reason:'protected_signal'});continue;
    }
    const hash=canonical({assertion:o.assertion,value:substantive(o.value)});
    if(next[key]===hash)reasons.push({id,reason:'refresh_or_no_substantive_change'});
    else {meaningful++;reasons.push({id,reason:'changed_or_no_baseline'});}
    next[key]=hash;
  }
  return {version:SHADOW_VERSION,policy:'SimpleRulesShadow',wake:meaningful>0,notify:false,execute:false,meaningful,reasons,next,sideEffects:false};
}
