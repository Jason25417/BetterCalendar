import { service } from "@/lib/service";
import { BridgeError, CallbackEndpointError } from "@/lib/bridge.mjs";
import { dotInstructions } from "@/lib/dot-instructions";
export const dynamic="force-dynamic";
const object=(properties:Record<string,unknown>={},required:string[]=[])=>({type:"object",properties,required,additionalProperties:false});
const string={type:"string"};
const tools=[
  {name:"read_current_state",description:"读取当前状态、来源新鲜度、正在计时的任务和近期说明；先读此工具再给建议。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"read_changes",description:"按游标读取完整变化记录；补传事件须按发生时间理解。",inputSchema:object({afterId:{type:"integer",minimum:0},limit:{type:"integer",minimum:1,maximum:100}}),annotations:{readOnlyHint:true}},
  {name:"read_instructions",description:"读取用户已批准的个人状态助手行为约定。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"task_command",description:"仅按用户明确表达开始、暂停、继续或结束计时。使用稳定 commandId 防止重试重复执行；非开始操作需先读会话 revision。保存成功后才能确认。",inputSchema:object({commandId:string,action:{type:"string",enum:["start","pause","resume","finish"]},title:string,sessionId:string,expectedRevision:{type:"integer"},occurredAt:{type:"string",format:"date-time"},provenance:{type:"string",enum:["user"]}},["commandId","action","provenance"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"read_task_history",description:"读取包含已结束任务的计时历史；开始时间范围使用带时区时间戳，最多100条。",inputSchema:object({from:{type:"string",format:"date-time"},before:{type:"string",format:"date-time"},limit:{type:"integer",minimum:1,maximum:100}}),annotations:{readOnlyHint:true}},
  {name:"acknowledge_batch",description:"仅在读取最新状态、补齐截断变化并完成本批理解后调用，记录 Dot 的实际处理时间；不能提前确认。",inputSchema:object({batchId:string},["batchId"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"record_context",description:"保存用户说明或单独标记的推断；推断必须引用依据，不会自动完成或暂停显式计时。",inputSchema:object({id:string,kind:string,body:{type:"object"},assertion:{type:"string",enum:["user","inferred"]},confidence:{type:"string",enum:["high","medium","low","unknown"]},basis:{type:"array",items:string},expiresAt:{type:"string",format:"date-time"},supersedes:string},["id","kind","body","assertion","confidence","basis"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"read_connection_status",description:"查看已登记设备、事件订阅与回调接收状态；不返回密钥。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"flush_minute_changes",description:"发送本分钟尚未发送的变化并重试待发送回调；一分钟最多一个新批次，没有变化不发。不能把回调接收当作 Dot 完成分析。",inputSchema:object(),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
];
const event={name:"state.minute_changed",description:"按分钟汇总全部有变化的个人状态；先读最新状态，再静默理解，只有必要时问或建议。",delivery:["webhook"],inputSchema:object(),payloadSchema:{type:"object",properties:{schemaVersion:{type:"integer"},readLatestState:{type:"boolean"},fromChangeId:{type:"integer"},throughChangeId:{type:"integer"},changes:{type:"array",items:{type:"object"}},omittedCount:{type:"integer"}},required:["schemaVersion","readLatestState","fromChangeId","throughChangeId","changes","omittedCount"],additionalProperties:false}};
export async function POST(request:Request){
  let id:unknown=null,methodForLog="unknown";
  try{
    const raw=await request.text();if(new TextEncoder().encode(raw).length>256*1024)throw new BridgeError("请求过大",413);
    const rpc=JSON.parse(raw);id=rpc.id??null;
    const p=rpc.params??{},method=rpc.method;
    if(["initialize","notifications/initialized","ping","server/discover","tools/list","events/list","events/subscribe","events/unsubscribe","tools/call"].includes(method))methodForLog=method;
    const result=(value:unknown)=>Response.json({jsonrpc:"2.0",id,result:value});
    if(method==="initialize")return result({protocolVersion:"2026-07-28",capabilities:{tools:{},events:{}},serverInfo:{name:"personal-state-bridge",version:"0.1.0"},instructions:"个人状态数据与持久化计时；先调用 read_instructions。"});
    if(method==="notifications/initialized")return new Response(null,{status:202});
    if(method==="ping")return result({});
    if(method==="server/discover")return result({resultType:"complete",supportedVersions:["2026-07-28"],capabilities:{tools:{},events:{}}});
    if(method==="tools/list")return result({tools});
    if(method==="events/list")return result({events:[event]});
    const owner=request.headers.get("oai-authenticated-user-id");
    if(!owner)throw new BridgeError("数据和订阅需要已认证用户身份",401);
    const core=service();
    if(method==="events/subscribe")return result(await core.subscribe(p,owner));
    if(method==="events/unsubscribe")return result(await core.unsubscribe(p,owner));
    if(method==="tools/call"){
      const a=p.arguments??{};let value;
      switch(p.name){
        case "read_current_state":value=await core.readState();break;
        case "read_changes":value=await core.readChanges(a.afterId??0,a.limit??100);break;
        case "read_instructions":value={instructions:dotInstructions};break;
        case "task_command":value=await core.taskCommand(a);break;
        case "read_task_history":value=await core.taskHistory(a);break;
        case "acknowledge_batch":value=await core.acknowledgeBatch(a.batchId,owner);break;
        case "record_context":value=await core.recordNote(a);break;
        case "read_connection_status":value=await core.diagnostics();break;
        case "flush_minute_changes":value=await core.flush();break;
        default:throw new BridgeError("未知工具",404);
      }
      return result({content:[{type:"text",text:JSON.stringify(value)}],structuredContent:value,isError:false});
    }
    return Response.json({jsonrpc:"2.0",id,error:{code:-32601,message:"未知方法"}});
  }catch(error){
    const message=error instanceof BridgeError?error.message:"接口暂不可用，请勿确认操作已完成";
    // Only protocol labels and categorized failures: never arguments, identities,
    // callback URLs, tokens, challenges, or device observations.
    console.warn("state-bridge-mcp-error",{method:methodForLog,kind:error instanceof CallbackEndpointError?"callback":error instanceof BridgeError?"request":"internal",status:error instanceof BridgeError?error.status:500,reason:error instanceof CallbackEndpointError?error.reason:undefined});
    return Response.json({jsonrpc:"2.0",id,error:{code:error instanceof CallbackEndpointError?-32015:error instanceof BridgeError&&error.status===401?-32001:-32602,message,...(error instanceof CallbackEndpointError?{data:{reason:error.reason}}:{})}}, {status:error instanceof BridgeError&&error.status===401?401:200});
  }
}
