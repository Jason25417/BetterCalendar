// 查询某 build 号在 App Store Connect 的处理/TestFlight 状态；可选第二参数=中文测试说明文件，写入并读回核验 zh-Hans。
// 用法：node scripts/asc-build.mjs <build号> [notes.txt]（自 Codex /private/tmp/bc-asc-build.mjs 收编，2026-10-17）
import fs from 'node:fs';
import crypto from 'node:crypto';
const build=process.argv[2];if(!/^\d+$/.test(build??''))throw Error('build required');
const noteFile=process.argv[3];
const b64=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
const now=Math.floor(Date.now()/1000),header=b64({alg:'ES256',kid:'MFLQ74N9N7',typ:'JWT'}),body=b64({iss:'f6b800c3-7e46-4bbb-914e-4c8ca018e8f1',iat:now,exp:now+600,aud:'appstoreconnect-v1'});
const signature=crypto.sign('sha256',Buffer.from(header+'.'+body),{key:fs.readFileSync(process.env.HOME+'/.appstoreconnect/private_keys/AuthKey_MFLQ74N9N7.p8'),dsaEncoding:'ieee-p1363'}).toString('base64url');
const token=header+'.'+body+'.'+signature;
async function request(path,method='GET',data){
 const r=await fetch('https://api.appstoreconnect.apple.com'+path,{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:data?JSON.stringify(data):undefined});
 const value=await r.json();if(!r.ok)throw Error('ASC '+r.status+' '+JSON.stringify(value.errors?.map(e=>({code:e.code,title:e.title,detail:e.detail}))));return value;
}
const list=await request('/v1/builds?filter[app]=6787325341&filter[version]='+build+'&limit=50');
const results=[];
for(const row of list.data){
 const release=(await request('/v1/builds/'+row.id+'/preReleaseVersion')).data;
 const beta=(await request('/v1/builds/'+row.id+'/buildBetaDetail')).data;
 let notesVerified=false;
 if(noteFile){
  const notes=fs.readFileSync(noteFile,'utf8').trim();
  const localizations=(await request('/v1/builds/'+row.id+'/betaBuildLocalizations')).data;
  const existing=localizations.find(x=>x.attributes.locale==='zh-Hans');
  if(existing){if(existing.attributes.whatsNew!==notes)await request('/v1/betaBuildLocalizations/'+existing.id,'PATCH',{data:{type:'betaBuildLocalizations',id:existing.id,attributes:{whatsNew:notes}}});}
  else await request('/v1/betaBuildLocalizations','POST',{data:{type:'betaBuildLocalizations',attributes:{locale:'zh-Hans',whatsNew:notes},relationships:{build:{data:{type:'builds',id:row.id}}}}});
  const check=(await request('/v1/builds/'+row.id+'/betaBuildLocalizations')).data;notesVerified=check.some(x=>x.attributes.locale==='zh-Hans'&&x.attributes.whatsNew===notes);
 }
 results.push({id:row.id,platform:release.attributes.platform,version:release.attributes.version,build:row.attributes.version,processing:row.attributes.processingState,internal:beta.attributes.internalBuildState,external:beta.attributes.externalBuildState,notesVerified});
}
console.log(JSON.stringify({build,checkedAt:new Date().toISOString(),builds:results},null,2));
