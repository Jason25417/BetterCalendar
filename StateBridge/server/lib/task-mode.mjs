import {BridgeError} from './bridge.mjs';
// Immutable start metadata; reaching the duration changes only presentation.
export const taskModeFields=['mode','focusMinutes','experiment'];
export function validateTaskMode(v){
 if(v.action!=='start'){
  if(taskModeFields.some(k=>v[k]!==undefined))throw new BridgeError('模式、番茄时长和实验标记仅在开始时指定');
  return;
 }
 const mode=v.mode??'light';
 if(!['light','pomodoro'].includes(mode)||v.experiment!==undefined&&typeof v.experiment!=='boolean')throw new BridgeError('计时模式或实验标记无效');
 if(mode==='pomodoro'){
  if(!Number.isSafeInteger(v.focusMinutes)||v.focusMinutes<1||v.focusMinutes>240)throw new BridgeError('番茄时长需要1至240整数分钟');
 }else if(v.focusMinutes!==undefined)throw new BridgeError('轻计时不能指定番茄时长');
}
