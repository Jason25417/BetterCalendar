// Deliberately pure: neither module has a network, notification or database
// writer. These proposals are research artifacts, not live permissions.
import { createHash } from 'node:crypto';
const revision=v=>createHash('sha256').update(JSON.stringify(v)).digest('hex');
const date=v=>typeof v==='string'&&/(Z|[+-]\d\d:\d\d)$/.test(v)&&Number.isFinite(Date.parse(v));
const permissions={notification:'notification.schedule',alarm:'alarm.schedule',pomodoro:'pomodoro.control',block_apps:'apps.block'};

export function reminderShadow(proposal,policy,{now,source,previous=[]}) {
  const reasons=[];const validDate= date(now)&&date(proposal.at);
  if(typeof proposal.commandId!=='string'||!proposal.commandId)reasons.push('missing_command_id');
  if(!validDate)reasons.push('invalid_time');
  if(!policy?.id||policy.revision<1||!policy.userAuthorizationRef||policy.enabled!==true)reasons.push('no_explicit_enabled_policy');
  if(!date(policy?.from)||!date(policy?.until)||Date.parse(policy.until)<=Date.parse(policy.from)||!validDate||Date.parse(now)<Date.parse(policy.from)||Date.parse(now)>=Date.parse(policy.until)||Date.parse(proposal.at)<Date.parse(now)||Date.parse(proposal.at)>=Date.parse(policy.until))reasons.push('outside_bounded_policy');
  if(!permissions[proposal.channel]||!policy?.permissions?.includes(permissions[proposal.channel]))reasons.push('channel_not_authorized');
  if(!policy?.eventKinds?.includes(proposal.eventKind))reasons.push('event_out_of_scope');
  if(!source?.id||!proposal.evidenceRefs?.includes(source.id)||source.assertion!=='user'||!date(source.observedAt)||!Number.isFinite(policy?.maxEvidenceAgeSeconds)||policy.maxEvidenceAgeSeconds<0||Date.parse(now)<Date.parse(source.observedAt)||Date.parse(now)-Date.parse(source.observedAt)>policy.maxEvidenceAgeSeconds*1000)reasons.push('missing_stale_or_unconfirmed_evidence');
  if(!Number.isFinite(proposal.durationSeconds)||proposal.durationSeconds<=0||!Number.isFinite(policy?.maxDurationSeconds)||policy.maxDurationSeconds<=0||proposal.durationSeconds>policy.maxDurationSeconds)reasons.push('duration_out_of_scope');
  if(!Array.isArray(policy?.quietWindows)||policy.quietWindows.some(w=>!date(w.from)||!date(w.until)||Date.parse(w.until)<=Date.parse(w.from)))reasons.push('quiet_time_policy_missing');
  else if(policy.quietWindows.some(w=>Date.parse(proposal.at)<Date.parse(w.until)&&Date.parse(proposal.at)+proposal.durationSeconds*1000>Date.parse(w.from))&&!policy.quietTimeExceptionAuthorizationRef)reasons.push('quiet_time');
  if(!policy?.revokeMethod||!policy?.releaseMethod)reasons.push('missing_revoke_or_release');
  if(!Number.isSafeInteger(policy?.maxPerHour)||policy.maxPerHour<1||!Number.isSafeInteger(policy?.maxPerDay)||policy.maxPerDay<1)reasons.push('frequency_policy_missing');
  const relevant=previous.filter(p=>p.policyId===policy?.id);
  if(relevant.some(p=>p.commandId===proposal.commandId))reasons.push('duplicate_command');
  if(validDate){for(const [window,limit] of [[3600000,policy?.maxPerHour],[86400000,policy?.maxPerDay]])if(relevant.filter(p=>date(p.at)&&Date.parse(p.at)<=Date.parse(proposal.at)&&Date.parse(proposal.at)-Date.parse(p.at)<window).length>=limit)reasons.push('frequency_limit');}
  return {version:1,commandId:proposal.commandId,policyId:policy?.id??null,policyRevision:policy?.revision??null,mode:'shadow',wouldAllow:!reasons.length,reasons:[...new Set(reasons)],proposal,
    effect:'none',execution:'not_requested',nativeCapability:'not_inspected',guaranteedWake:false};
}

export function itemDraft(record,command,{now}) {
  if(!date(now)||!command.commandId||!command.userAuthorizationRef)throw Error('explicit request and timestamp required');
  if(command.recordId!==record.id||command.expectedRevision!==record.revision)throw Error('item version conflict; reread before proposing');
  if(!['update','delete','restore'].includes(command.action))throw Error('unsupported prototype action');
  const original=structuredClone(record.values),proposed=structuredClone(original);
  if(command.action==='update') {
    const allowed=['title','note','status','zone'];
    if(!command.patch||Object.keys(command.patch).some(k=>!allowed.includes(k)))throw Error('unsupported item field; identity and inferred facts cannot overwrite confirmed data');
    if(command.patch.title!==undefined&&(typeof command.patch.title!=='string'||!command.patch.title.trim()||command.patch.title.length>300))throw Error('invalid title');
    if(command.patch.note!==undefined&&(typeof command.patch.note!=='string'||command.patch.note.length>20000))throw Error('invalid note');
    if(command.patch.status!==undefined&&!['active','done','shelved'].includes(command.patch.status))throw Error('invalid status');
    if(command.patch.zone!==undefined&&!['longterm','todo'].includes(command.patch.zone))throw Error('invalid zone');
    Object.assign(proposed,command.patch);
  }else if(command.action==='delete'){
    if(original.zone!=='todo'||original.isInTrash)throw Error('longterm items use shelved; only live todo items may enter trash');
    // Match the pool's unix-milliseconds and SwiftData UUID field encoding.
    const h=revision(command.commandId);
    proposed.isInTrash=true;proposed.deletionId=[h.slice(0,8),h.slice(8,12),h.slice(12,16),h.slice(16,20),h.slice(20,32)].join('-');proposed.deletedAt=Date.parse(now);
  }else{if(!original.isInTrash)throw Error('item is not in trash');proposed.isInTrash=false;proposed.restoredDeletionId=original.deletionId;}
  return {version:1,commandId:command.commandId,recordId:record.id,expectedRevision:record.revision,mode:'draft',permission:`items.${command.action}`,original,proposed,
    proposedRevision:revision(proposed),recoverable:true,minimumRetentionDays:30,execution:'not_requested',sideEffects:false,
    interpretation:'只生成可审阅的差异与原文；未写入SwiftData、CloudKit或另一套事项库。执行前必须再次核对真实版本与独立权限。'};
}
