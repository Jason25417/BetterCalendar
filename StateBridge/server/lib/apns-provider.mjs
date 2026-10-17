// Offline-prepared transport, intentionally not wired to any runtime route.
// Enabling/registering real tokens or configuring credentials needs consent.
const utf8=new TextEncoder(),topic='com.jason.BetterCalendar';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const domains={production:'https://api.push.apple.com',sandbox:'https://api.sandbox.push.apple.com'};
const reasons={400:['BadCollapseId','BadDeviceToken','BadExpirationDate','BadMessageId','BadPriority','BadTopic','DeviceTokenNotForTopic','DuplicateHeaders','IdleTimeout','InvalidPushType','MissingDeviceToken','MissingTopic','PayloadEmpty','TopicDisallowed'],403:['BadCertificate','BadCertificateEnvironment','ExpiredProviderToken','Forbidden','InvalidProviderToken','MissingProviderToken'],404:['BadPath'],405:['MethodNotAllowed'],410:['ExpiredToken','Unregistered'],413:['PayloadTooLarge'],429:['TooManyProviderTokenUpdates','TooManyRequests'],500:['InternalServerError'],503:['ServiceUnavailable','Shutdown']};
const b64=bytes=>btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
const json64=v=>b64(utf8.encode(JSON.stringify(v)));
export class APNsInputError extends Error { constructor(){super('APNs request validation failed; no request sent');} }
function validRequest(v,at){
 if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!['token','environment','apnsId','collapseId','expiresAt','kind','payload'].includes(k))||
    typeof v.token!=='string'||!(/^(?:[0-9a-f]{2})+$/i).test(v.token)||v.token.length>4096||
    typeof v.environment!=='string'||!Object.hasOwn(domains,v.environment)||!uuid.test(v.apnsId)||typeof v.collapseId!=='string'||!v.collapseId||utf8.encode(v.collapseId).length>64||
    !['alert','background'].includes(v.kind)||!Number.isFinite(Date.parse(v.expiresAt))||Date.parse(v.expiresAt)<=at||Date.parse(v.expiresAt)>at+86400000||
    !v.payload||typeof v.payload!=='object'||Array.isArray(v.payload)||!v.payload.aps||typeof v.payload.aps!=='object'||Array.isArray(v.payload.aps))throw new APNsInputError();
 const aps=v.payload.aps;
 if(v.kind==='background'&&(aps['content-available']!==1||['alert','sound','badge'].some(k=>Object.hasOwn(aps,k)))||v.kind==='alert'&&!aps.alert)throw new APNsInputError();
 let body;try{body=JSON.stringify(v.payload);}catch{throw new APNsInputError();}
 if(utf8.encode(body).length>4096)throw new APNsInputError();
 return body;
}
async function boundedJSON(response){
 const reader=response.body?.getReader();if(!reader)return null;
 const chunks=[];let total=0;
 try{for(;;){const {done,value}=await reader.read();if(done)break;total+=value.byteLength;if(total>4096){await reader.cancel();return null;}chunks.push(value);}}
 catch{return null;}
 const bytes=new Uint8Array(total);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
 try{return JSON.parse(new TextDecoder().decode(bytes));}catch{return null;}
}

export function createAPNsProvider({enabled=()=>false,fetcher=null,credentials=()=>null,now=()=>Date.now()}={}){
 let cached=null;
 async function jwt(at){
  const value=await credentials();
  if(!value||typeof value.teamId!=='string'||typeof value.keyId!=='string'||!(/^[A-Z0-9]{10}$/).test(value.teamId)||!(/^[A-Z0-9]{10}$/).test(value.keyId)||typeof value.privateKey!=='string'||value.privateKey.length>16384)throw new Error('invalid configuration');
  if(cached&&cached.teamId===value.teamId&&cached.keyId===value.keyId&&cached.pem===value.privateKey&&at>=cached.issuedAt&&at-cached.issuedAt<1200000)return cached.token;
  const match=value.privateKey.trim().match(/^-----BEGIN PRIVATE KEY-----\s+([A-Za-z0-9+/=\s]+)\s+-----END PRIVATE KEY-----$/);
  if(!match)throw new Error('invalid configuration');
  const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(match[1].replace(/\s/g,'')),c=>c.charCodeAt(0)),{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
  const header=json64({alg:'ES256',kid:value.keyId}),claims=json64({iss:value.teamId,iat:Math.floor(at/1000)}),input=header+'.'+claims;
  const signature=new Uint8Array(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,utf8.encode(input)));
  if(signature.length!==64)throw new Error('unsupported signature representation');
  cached={teamId:value.teamId,keyId:value.keyId,pem:value.privateKey,issuedAt:at,token:input+'.'+b64(signature)};return cached.token;
 }
 async function send(v){
  if(enabled()!==true)return {outcome:'not_sent',stage:'disabled'};
  const at=now(),body=validRequest(v,at);
  if(typeof fetcher!=='function')return {outcome:'not_sent',stage:'transport_unconfigured'};
  let authorization;try{authorization=await jwt(at);}catch{return {outcome:'not_sent',stage:'configuration'};}
  let response;
  try{response=await fetcher(domains[v.environment]+'/3/device/'+v.token,{method:'POST',redirect:'error',headers:{authorization:'bearer '+authorization,'apns-topic':topic,'apns-id':v.apnsId,'apns-collapse-id':v.collapseId,'apns-expiration':String(Math.floor(Date.parse(v.expiresAt)/1000)),'apns-push-type':v.kind,'apns-priority':v.kind==='background'?'5':'10','content-type':'application/json'},body,signal:AbortSignal.timeout(10000)});}
  catch{return {outcome:'unknown',stage:'transport',apnsId:v.apnsId,userSeen:'unknown'};}
  // An HTTP success is only provider acceptance; never device/human evidence.
  const id=response.headers.get('apns-id');
  if(!id||id.toLowerCase()!==v.apnsId.toLowerCase())return {outcome:'unknown',stage:'response_identity',status:response.status,apnsId:v.apnsId,userSeen:'unknown'};
  if(response.status===200)return {outcome:'provider_accepted',apnsId:v.apnsId,userSeen:'unknown',deviceReceived:'unknown'};
  const data=await boundedJSON(response),reason=reasons[response.status]?.includes(data?.reason)?data.reason:null;
  if(!reason)return {outcome:'unknown',stage:'unrecognized_response',status:response.status,apnsId:v.apnsId,userSeen:'unknown'};
  const invalidationAt=response.status===410&&Number.isFinite(data.timestamp)&&data.timestamp>=0?data.timestamp:null;
  return {outcome:'rejected',apnsId:v.apnsId,status:response.status,reason,retryable:[500,503].includes(response.status)||reason==='TooManyRequests',tokenInvalidatedAt:invalidationAt,userSeen:'unknown'};
 }
 return {send};
}
