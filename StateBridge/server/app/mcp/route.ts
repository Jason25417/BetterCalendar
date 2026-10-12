import { service } from "@/lib/service";
import { BridgeError, CallbackEndpointError } from "@/lib/bridge.mjs";
import { dotInstructions } from "@/lib/dot-instructions";
export const dynamic="force-dynamic";
const object=(properties:Record<string,unknown>={},required:string[]=[])=>({type:"object",properties,required,additionalProperties:false});
const string={type:"string"};
const tools=[
  {name:"read_research_log",description:"分页读取本轮上线以后真实BC工具调用的参数摘要、原文定位、结果哈希、错误和处理回执。没有日志不等于未调用；外部连接器及私有思维链未捕获。研究原文由本地记录器下载，不上传新服务。",inputSchema:object({afterId:{type:"integer",minimum:0},throughId:{type:"integer",minimum:0},limit:{type:"integer",minimum:1,maximum:100}}),annotations:{readOnlyHint:true}},
  {name:"complete_batch",description:"完整读完事件变化和状态正文后保存有证据的结论、提醒/操作结果及注意力成本，再原子确认本批。readCallIds使用真实工具返回的research.callId；分页读完才允许确认。此工具不会通知、计时或对外写入；reported_sent只是代理报告。无用户反馈记unknown。纠正用supersedes保留原结果。",inputSchema:object({batchId:string,resultId:string,readCallIds:{type:"array",items:string},conclusions:{type:"array",items:{type:"object",properties:{summary:string,sourceClass:{type:"string",enum:["bc_native","connector","user_statement","public","habit","inference"]},confidence:{type:"string",enum:["high","medium","low","unknown"]},rationale:string,evidenceCallIds:{type:"array",items:string},alternatives:{type:"array",items:string}},required:["summary","sourceClass","confidence","rationale","evidenceCallIds","alternatives"],additionalProperties:false}},notification:{type:"object",properties:{channel:{type:"string",enum:["silent","chat","ordinary_notification"]},result:{type:"string",enum:["not_requested","reported_sent","unknown","failed"]}},required:["channel","result"],additionalProperties:false},operation:{type:"object",properties:{kind:{type:"string",enum:["none","task_command"]},commandId:string},required:["kind"],additionalProperties:false},attention:{type:"object",properties:{seconds:{type:"number",minimum:0},basis:{type:"string",enum:["user_report","agent_estimate"]}},additionalProperties:false},supersedes:string},["batchId","resultId","readCallIds","notification","operation"]),annotations:{readOnlyHint:false,destructiveHint:false}},
  {name:"read_pool_records",description:"分页读取BC设备SwiftData中的长期事项、愿望/待办、已完成和已放下目录，包含阶段、完整字段和内容版本。它是带来源/时效的只读副本，不迁移或另存任务真相；不同设备可能尚未同步。默认隐藏回收站，可显式includeTrash。hasMore时以相同筛选及nextCursor继续，分页固定该快照。未上传/读取失败不等于没有事项；尚无编辑能力。",inputSchema:object({deviceId:string,zone:{type:"string",enum:["longterm","todo"]},status:{type:"string",enum:["active","done","shelved"]},includeTrash:{type:"boolean"},limit:{type:"integer",minimum:1,maximum:100},cursor:string}),annotations:{readOnlyHint:true}},
  {name:"read_current_state",description:"读取个人状态、来源时效、覆盖和BC计时。事件处理可先includeValues=false读摘要，再用sourceKeys读取所需正文；valuesIncluded=false不是不可读。默认保留旧版完整读取。stale是旧数据，not_received是未上传，不等于无权限。",inputSchema:object({includeValues:{type:"boolean"},sourceKeys:{type:"array",items:string,maxItems:40}}),annotations:{readOnlyHint:true}},
  {name:"read_changes",description:"按游标分页读取完整变化；按发生时间理解补传。响应大小有界，hasMore时继续nextCursor；可设throughId只读到事件的throughChangeId，避免追逐新变化而一直不能结束本批。",inputSchema:object({afterId:{type:"integer",minimum:0},limit:{type:"integer",minimum:1,maximum:100},throughId:{type:"integer",minimum:0}}),annotations:{readOnlyHint:true}},
  {name:"read_observation_history",description:"按 sourceKey 和发生时间查询一个来源的原始历史；保留未知版本和字段，区分发生与接收时间。每页最多100条，hasMore时以相同范围及nextCursor继续；补传后复核需重读完整时间窗。不能把历史当实时状态。",inputSchema:object({sourceKey:string,from:{type:"string",format:"date-time"},before:{type:"string",format:"date-time"},limit:{type:"integer",minimum:1,maximum:100},cursor:string},["sourceKey"]),annotations:{readOnlyHint:true}},
  {name:"read_instructions",description:"读取用户已批准的个人状态助手行为约定。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"task_command",description:"仅按用户明确表达开始、暂停、继续或结束计时，与BC按钮使用同一记录。结束计时不标记事项完成。使用稳定commandId防重；非开始操作先读revision。开始时可传relatedRecordId关联旧计划ID，不迁移或改写旧记录。返回saved=true才确认。",inputSchema:object({commandId:string,action:{type:"string",enum:["start","pause","resume","finish"]},title:string,sessionId:string,expectedRevision:{type:"integer"},occurredAt:{type:"string",format:"date-time"},provenance:{type:"string",enum:["user"]},relatedRecordId:string},["commandId","action","provenance"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"read_task_history",description:"分页读取BC云端计时的最新记录，包含已结束任务；按开始时间查询，读到hasMore=false。分页不冻结状态，旧SwiftData历史尚未迁移。",inputSchema:object({from:{type:"string",format:"date-time"},before:{type:"string",format:"date-time"},limit:{type:"integer",minimum:1,maximum:100},cursor:{type:"string"}}),annotations:{readOnlyHint:true}},
  {name:"read_task_commands",description:"按服务端保存时间分页读取BC计时原始操作回执；可按sessionId筛选，读到hasMore=false。回执用于核对保存证据，不会重放操作或修改记录。",inputSchema:object({sessionId:{type:"string"},from:{type:"string",format:"date-time"},before:{type:"string",format:"date-time"},limit:{type:"integer",minimum:1,maximum:100},cursor:{type:"string"}}),annotations:{readOnlyHint:true}},
  {name:"acknowledge_batch",description:"仅在读取最新状态、补齐截断变化并完成本批理解后调用，记录 Dot 的实际处理时间；不能提前确认。",inputSchema:object({batchId:string},["batchId"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"record_context",description:"保存用户说明或单独标记的推断；推断必须引用依据，不会自动完成或暂停显式计时。缓存兼容：kind=bc.research.batch_result时body为完整研究结果，转交complete_batch同一校验入口，不新增活动推断。",inputSchema:object({id:string,kind:string,body:{type:"object"},assertion:{type:"string",enum:["user","inferred"]},confidence:{type:"string",enum:["high","medium","low","unknown"]},basis:{type:"array",items:string},expiresAt:{type:"string",format:"date-time"},supersedes:string},["id","kind","body","assertion","confidence","basis"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"read_connection_status",description:"查看已登记设备、事件订阅与回调接收状态；不返回密钥。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"flush_minute_changes",description:"发送本分钟尚未发送的变化并重试待发送回调；一分钟最多一个新批次，没有变化不发。不能把回调接收当作 Dot 完成分析。",inputSchema:object(),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
];
const event={name:"state.minute_changed",description:"按分钟汇总全部有变化的个人状态；先读最新状态，再静默理解，只有必要时问或建议。",delivery:["webhook"],inputSchema:object(),payloadSchema:{type:"object",properties:{schemaVersion:{type:"integer"},readLatestState:{type:"boolean"},fromChangeId:{type:"integer"},throughChangeId:{type:"integer"},changes:{type:"array",items:{type:"object"}},omittedCount:{type:"integer"},decision:{type:"object"}},required:["schemaVersion","readLatestState","fromChangeId","throughChangeId","changes","omittedCount"],additionalProperties:false}};
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
      const a=p.arguments??{};
      const value=await core.research.invoke(p.name,a,owner,async()=>{let value;
      switch(p.name){
        case "read_research_log":value=await core.research.read(a);break;
        case "complete_batch":value=await core.research.complete(a,owner);break;
        case "read_pool_records":value=await core.readPoolRecords(a);break;
        case "read_current_state":value=await core.readState(a);break;
        case "read_changes":value=await core.readChanges(a.afterId??0,a.limit??100,a.throughId??null);break;
        case "read_observation_history":value=await core.readObservationHistory(a);break;
        case "read_instructions":value={instructions:dotInstructions};break;
        case "task_command":value=await core.taskCommand(a);break;
        case "read_task_history":value=await core.taskHistory(a);break;
        case "read_task_commands":value=await core.readTaskCommands(a);break;
        case "acknowledge_batch":value=await core.acknowledgeBatch(a.batchId,owner);break;
        case "record_context":value=await core.recordContext(a,owner);break;
        case "read_connection_status":value=await core.diagnostics();break;
        case "flush_minute_changes":value=await core.flush();break;
        default:throw new BridgeError("未知工具",404);
      }
      return value;});
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
