"use client";
import { useState, useEffect } from "react";
type State = { readAt:string; sources:{sourceKey:string;observedAt:string;freshness:string;availability?:string;value:unknown}[];sessions:{id:string;title:string;status:string;elapsedMs:number}[];coverage?:{deviceId:string;label:string;revoked:boolean;sources:{source:string;availability:string}[]}[];warnings?:{code:string;explanation:string}[] };
const sourceStatus:Record<string,string>={available:"可读取",partial:"部分可读取",empty:"已读取，结果为空",unknown:"结果不足以判断",error:"读取出错",not_configured:"尚未配置",not_authorized:"尚未授权",not_received:"尚未收到上传"};
export default function Home(){
  const [state,setState]=useState<State|null>(null),[error,setError]=useState(""),[needsSignIn,setNeedsSignIn]=useState(false);
  async function refresh(){try{const r=await fetch("/api/state",{cache:"no-store"});setNeedsSignIn(r.status===401);const value=await r.json() as State & {error?:string};if(!r.ok){setState(null);throw new Error(value.error ?? "读取失败");}setState(value);setError("");}catch(e){setError(e instanceof Error?e.message:"暂时无法读取");}}
  async function enroll(platform:"mac"|"iphone") {
    try { const response=await fetch("/api/devices/enroll",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({platform})});
      setNeedsSignIn(response.status===401);const config=await response.json() as {error?:string}; if(!response.ok)throw new Error(config.error ?? "连接配置生成失败");
      await navigator.clipboard.writeText(JSON.stringify(config)); setError("设备配置已复制。粘贴到内测 App 设置 → 个人状态与 Dot → 保存连接。");
    } catch(e){setError(e instanceof Error?e.message:"无法生成配置");}
  }
  useEffect(()=>{refresh();const timer=setInterval(refresh,60000);return()=>clearInterval(timer);},[]);
  return <main style={{maxWidth:920,margin:"48px auto",padding:"0 24px",lineHeight:1.7}}>
    <p style={{color:"#777"}}>Jason · 个人状态接入</p><h1 style={{fontSize:32}}>让 Dot 了解此刻。</h1>
    <p>设备各自采集，每分钟汇总变化。你在对话里说开始、暂停或结束；明确计时与状态推断分别保存。</p>
    <button onClick={refresh} style={{padding:"8px 18px",border:"1px solid #888",borderRadius:8}}>刷新状态</button>
    {error&&<p role="alert">{error}</p>}
    {needsSignIn&&<p>请先用同一 ChatGPT 账户登录，再复制设备配置。<a href="/signin-with-chatgpt?return_to=/" target="_top" style={{marginLeft:8}}>用 ChatGPT 登录</a></p>}
    <h2 style={{marginTop:32}}>连接设备</h2><p>在这台设备复制一次配置，粘贴进内测 App 的个人状态设置，启用采集并接受系统权限。配置只存本机 Keychain，请不要分享给其他人。</p><div style={{display:"flex",gap:12,flexWrap:"wrap"}}><button onClick={()=>enroll("mac")} style={{padding:"8px 16px",border:"1px solid #888",borderRadius:8}}>复制 Mac 配置</button><button onClick={()=>enroll("iphone")} style={{padding:"8px 16px",border:"1px solid #888",borderRadius:8}}>复制 iPhone 配置</button></div>
    <h2 style={{marginTop:32}}>任务计时</h2>{state?.sessions.length?state.sessions.map(s=><p key={s.id}>{s.title} · {s.status==="running"?"进行中":"已暂停"} · {Math.floor(s.elapsedMs/60000)} 分钟</p>):<p>暂无已保存的进行中任务。</p>}
    <h2 style={{marginTop:32}}>数据来源</h2>{state?.warnings?.map(w=><p key={w.code} role="status">{w.explanation}</p>)}{state?.sources.length?<div style={{overflowX:"auto"}}><table style={{width:"100%",textAlign:"left"}}><thead><tr><th>来源</th><th>最后观察</th><th>时效</th><th>读取情况</th></tr></thead><tbody>{state.sources.map(s=><tr key={s.sourceKey}><td>{s.sourceKey}</td><td>{new Date(s.observedAt).toLocaleString()}</td><td>{s.freshness==="current"?"尚在有效期":"已过期"}</td><td>{sourceStatus[s.availability??""]??"旧版记录，需单独判断"}</td></tr>)}</tbody></table></div>:<p>还没有收到设备观察。采集端启动并完成系统权限后才会出现。</p>}
    {state?.coverage?.filter(d=>!d.revoked&&d.sources.some(s=>s.availability==="not_received")).map(d=><p key={d.deviceId} style={{color:"#777"}}>{d.label} 尚未上传的来源：{d.sources.filter(s=>s.availability==="not_received").map(s=>s.source).join("、")}。登记来源权限不表示采集已配置。</p>)}
    <p style={{marginTop:36,color:"#777"}}>旧观察不会覆盖较新的状态。无法读取、离线或权限不足只表示缺少信息，不代表你在睡觉或没有做事。</p>
    {state&&<p style={{color:"#777"}}>读取时间：{new Date(state.readAt).toLocaleString()}</p>}
  </main>;
}
