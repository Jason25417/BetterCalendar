import { service } from "@/lib/service";
import { BridgeError } from "@/lib/bridge.mjs";
import { env } from "cloudflare:workers";
export const dynamic = "force-dynamic";
const json = (v: unknown, status=200) => Response.json(v,{status,headers:{"Cache-Control":"no-store"}});
export async function POST(request:Request,context:{params:Promise<{path:string[]}>}) {
  try {
    const path=(await context.params).path.join("/"),core=service();
    if(Number(request.headers.get("content-length"))>256*1024)throw new BridgeError("请求过大",413);
    const text=await request.text();if(new TextEncoder().encode(text).length>256*1024)throw new BridgeError("请求过大",413);
    const body=text?JSON.parse(text):{};
    // This entire Site is owner-private at the Sites dispatch boundary. Ingest/flush
    // additionally require a scoped device token. The service credential alone
    // does not grant access to the user's connected apps or their identity.
    if(path==="devices/register") {
      // A clock/probe has a service credential for dispatch, not authority to
      // enroll a new interactive device with broader personal-data scopes.
      if(!request.headers.get("oai-authenticated-user-id"))throw new BridgeError("设备登记需要已登录的账户",401);
      return json(await core.registerDevice(body));
    }
    if(path==="ingest"||path==="flush"||path==="pool/upload"){
      const device=await core.authenticateDevice(request.headers.get("Authorization")?.replace(/^Bearer /,""));
      return json(await core.research.invoke(path,body,`device:${device.id}`,()=>path==="pool/upload"?core.uploadPool(body,device):path==="ingest"?core.ingest(body,device):core.flush()));
    }
    if(path.startsWith("research/")){
      const device=await core.authenticateDevice(request.headers.get("Authorization")?.replace(/^Bearer /,""));
      if(!JSON.parse(device.scopes).includes("user.context"))throw new BridgeError("此设备未登记个人研究读取权限",403);
      // Read-only local archiver: cannot acknowledge, send or operate timing.
      if(path==="research/log")return json(await core.research.read(body));
      if(path==="research/batches")return json(await core.research.batches(body));
      if(path==="research/changes")return json(await core.readChanges(body.afterId??0,body.limit??100,body.throughId??null));
      if(path==="research/state")return json(await core.readState(body));
      if(path==="research/evidence")return json(await core.research.evidence(body));
      throw new BridgeError("未知研究读取接口",404);
    }
    if(path==="tasks/state"||path==="tasks/command"||path==="pool/read"){
      const device=await core.authenticateDevice(request.headers.get("Authorization")?.replace(/^Bearer /,""));
      // Only the owner's enrolled interactive devices can participate in task
      // timing. Clock/probe tokens cannot read or control personal sessions.
      if(!JSON.parse(device.scopes).includes("user.context"))throw new BridgeError("此设备未登记个人任务操作权限",403);
      return json(await core.research.invoke(path,body,`device:${device.id}`,()=>path==="pool/read"?core.readPoolRecords(body):path==="tasks/state"?core.taskState():core.taskCommand(body,`device:${device.id}`)));
    }
    if(!request.headers.get("oai-authenticated-user-id"))throw new BridgeError("需要已登录的用户",401);
    if(path==="devices/enroll") {
      if(!["mac","iphone"].includes(body.platform))throw new BridgeError("设备平台无效");
      if(!env.STATE_BRIDGE_SERVICE_TOKEN || !env.STATE_BRIDGE_ORIGIN)throw new BridgeError("设备配置尚未就绪",503);
      const common=["calendar.events","reminders.items","device.status","source.status","ios.app","ios.focus","home.occupancy","user.context"];
      const scopes=[...common,...(body.platform==="mac"?["mac.activity","mac.browser","mac.history","files.activity"]:["health.status","health.sleep","health.steps","health.resting-heart-rate","health.workouts","ios.location","ios.visit","ios.motion","home.status"])];
      const device=await core.registerDevice({id:`${body.platform}_${crypto.randomUUID()}`,label:body.platform==="mac"?"Jason Mac":"Jason iPhone",scopes});
      return json({siteURL:env.STATE_BRIDGE_ORIGIN,platformToken:env.STATE_BRIDGE_SERVICE_TOKEN,deviceToken:device.token,deviceId:device.id});
    }
    if(path==="devices/revoke")return json(await core.revokeDevice(body.id));
    return json({error:"找不到接口"},404);
  }catch(error){return json({error:error instanceof BridgeError?error.message:"服务暂不可用；请求没有被确认为已完成"},error instanceof BridgeError?error.status:500);}
}
export async function GET(request:Request,context:{params:Promise<{path:string[]}>}) {
  try{
    if(!request.headers.get("oai-authenticated-user-id"))throw new BridgeError("需要已登录的用户",401);
    const path=(await context.params).path.join("/"),core=service();
    if(path==="state")return json(await core.readState());
    if(path==="diagnostics")return json(await core.diagnostics());
    if(path==="changes")return json(await core.readChanges(Number(new URL(request.url).searchParams.get("after")??0)));
    return json({error:"找不到接口"},404);
  }catch(error){return json({error:error instanceof BridgeError?error.message:"服务暂不可用"},error instanceof BridgeError?error.status:500);}
}
