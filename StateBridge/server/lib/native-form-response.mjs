import {BridgeError} from './bridge.mjs';
const object=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const type=v=>v===null?'null':Array.isArray(v)?'array':typeof v;
// Structural evidence only: no metadata, form text, token or arbitrary values.
export function formResponseShape(v){
 const known=['action','content','resultType','_meta'];
 return {responseType:type(v),presentFields:object(v)?known.filter(k=>Object.hasOwn(v,k)):[],unknownEnvelopeFieldCount:object(v)?Object.keys(v).filter(k=>!known.includes(k)).length:null,
  resultTypeType:type(v?.resultType),metadataType:type(v?._meta),contentType:type(v?.content),contentFieldCount:object(v?.content)?Object.keys(v.content).length:null,
  confirmType:type(v?.content?.confirm),reviewType:type(v?.content?.review),unknownContentFieldCount:object(v?.content)?Object.keys(v.content).filter(k=>!['confirm','review'].includes(k)).length:null};
}
export function normalizeFormResponse(v,variant='boolean'){
 if(!object(v)||Object.keys(v).some(k=>!['action','content','resultType','_meta'].includes(k)))throw new BridgeError('确认响应包含不支持的外层字段');
 if(v.resultType!==undefined&&v.resultType!=='complete'||v._meta!==undefined&&!object(v._meta))throw new BridgeError('确认响应协议元数据格式无效');
 if(!['accept','decline','cancel'].includes(v.action))throw new BridgeError('原生确认结果无效');
 if(v.action!=='accept'){
  if(v.content!==undefined&&v.content!==null)throw new BridgeError('取消确认不能混入确认内容');
  return {action:v.action};
 }
 const fields=variant==='review'?['confirm','review']:['confirm'];
 if(!object(v.content)||Object.keys(v.content).some(k=>!fields.includes(k))||!Object.hasOwn(v.content,'confirm'))throw new BridgeError('确认响应包含不支持的内容字段');
 if(variant==='choice'){
  if(!['不执行','确认显示测试'].includes(v.content.confirm))throw new BridgeError('显示测试需要明确选择');
 }else if(typeof v.content.confirm!=='boolean')throw new BridgeError('原生确认需要本人明确选择');
 if(variant==='review'&&typeof v.content.review!=='string')throw new BridgeError('显示测试摘要字段无效');
 return {action:'accept',content:{...v.content}};
}
