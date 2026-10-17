import {APNsInputError} from './apns-provider.mjs';
// Store must implement durable atomic claim/finish. This is not wired to D1 or
// native token registration yet. A stable APNs ID is not exactly-once proof.
export function createAPNsAttempt({store,provider,authorize,now=()=>Date.now()}){
 return async function attempt(id){
  let job;try{job=await store.get(id);}catch{return {outcome:'unknown',stage:'job_read_failed'};}
  if(!job)return {outcome:'not_sent',stage:'missing_job'};
  if(typeof job.deviceId!=='string'||!job.deviceId||typeof job.commandId!=='string'||
     !(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i).test(job.commandId)||
     !(/^[0-9a-f]{64}$/).test(job.requestHash)||!Number.isSafeInteger(job.revision)||job.revision<1||
     !Number.isSafeInteger(job.tokenVersion)||job.tokenVersion<1||!Number.isSafeInteger(job.grantRevision)||job.grantRevision<1||
     job.reviewerRevision!==null&&(!Number.isSafeInteger(job.reviewerRevision)||job.reviewerRevision<1)||!job.request)return {outcome:'not_sent',stage:'invalid_job_binding'};
  if(job.phase==='reserved')return {outcome:'unknown',stage:'unfinished_attempt',apnsId:job.request.apnsId};
  if(job.phase!=='ready')return job.result??{outcome:'not_sent',stage:job.phase};
  let check;try{check=await authorize(job);}catch{return {outcome:'not_sent',stage:'authorization_unknown'};}
  function allowed(v){return v?.allowed===true&&v.commandId===job.commandId&&v.requestHash===job.requestHash&&v.deviceId===job.deviceId&&v.tokenVersion===job.tokenVersion&&v.state==='awaiting_confirmation'&&v.grantRevision===job.grantRevision&&v.reviewerRevision===job.reviewerRevision&&v.expectedRevision===job.expectedRevision&&v.expiresAt===job.request.expiresAt&&Date.parse(v.expiresAt)>now();}
  if(!allowed(check))return {outcome:'not_sent',stage:'not_currently_authorized'};
  let claimed;try{claimed=await store.claim(job.id,job.revision);}catch{return {outcome:'unknown',stage:'reservation_not_confirmed'};}
  if(!claimed)return {outcome:'unknown',stage:'already_claimed'};
  let result;
  // Recheck after durable reservation so closure/revocation in that interval
  // never enters the provider. An error leaves the reserved intent unknown.
  try{check=await authorize(job);}catch{return {outcome:'unknown',stage:'authorization_unknown_after_claim'};}
  if(!allowed(check))result={outcome:'not_sent',stage:'closed_or_revoked_after_claim'};
  else{
   try{result=await provider.send(job.request);}catch(error){result=error instanceof APNsInputError?{outcome:'not_sent',stage:'request_validation'}:{outcome:'unknown',stage:'provider_exception'};}
   if(!['provider_accepted','rejected','unknown','not_sent'].includes(result?.outcome)||result.apnsId!==undefined&&result.apnsId!==job.request.apnsId)result={outcome:'unknown',stage:'provider_receipt_binding'};
  }
  const phase=result.outcome==='provider_accepted'?'provider_accepted':result.outcome==='unknown'?'unknown':result.outcome==='rejected'?'rejected':'blocked';
  try{if(!await store.finish(job.id,job.revision+1,phase,result))return {outcome:'unknown',stage:'receipt_not_persisted'};}
  catch{return {outcome:'unknown',stage:'receipt_not_persisted'};}
  // An explicit rejection can be requeued only by a future bounded scheduler
  // after authorization and timing rechecks. No auto retry or local fallback.
  return result;
 };
}
