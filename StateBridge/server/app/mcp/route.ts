import { service } from "@/lib/service";
import { BridgeError, CallbackEndpointError, canonical, sha } from "@/lib/bridge.mjs";
import { dotInstructions } from "@/lib/dot-instructions";
import { nativeConfirmationUri, nativeConfirmationHtml, nativeToolResult, nativeCommandOutputSchema } from "@/lib/native-confirmation.mjs";
import { nativeUUIDSchema } from "@/lib/native-commands.mjs";
import { clientConfirmationCapabilities } from "@/lib/mcp-client-capabilities.mjs";
import { supportsNativeForm, nativeFormResponse, nativeFormInputShape, finalizeNativeForm, previewNativeForm } from "@/lib/native-form-confirmation.mjs";
import { safeArguments } from "@/lib/research.mjs";
import {confirmationPresentation} from "@/lib/confirmation-presentation.mjs";
import {formResponseShape} from "@/lib/native-form-response.mjs";
export const dynamic="force-dynamic";
const object=(properties:Record<string,unknown>={},required:string[]=[])=>({type:"object",properties,required,additionalProperties:false});
const string={type:"string"};
const tools=[
  {name:"preview_native_confirmation",description:"仅在用户要求检查确认界面时，用已有commandId重现只读显示测试。确认/取消均不执行、不重建原操作，不修改事项、计时、权限或活动记录。原请求保持原状态。不是重新提交失败操作的入口；不得自动重复调用。",inputSchema:object({commandId:nativeUUIDSchema},["commandId"]),annotations:{readOnlyHint:true,destructiveHint:false}},
  {name:"read_native_capabilities",description:"查看用户在原生设置主动启用的指定设备、事项、独立共享计时、单次闹钟及独立日记读取/文字修改权限和期限。能力启用不证明设备在线或系统授权仍有效；每次改动仍需对话内确认。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"submit_native_command",outputSchema:nativeCommandOutputSchema,description:"按用户明确请求提出BC事项、共享计时、日记文字、单次普通提醒或原生闹钟改动。固定UUID格式commandId和指定设备；聊天表单和指定设备BC待确认同时可用，指向同一commandId/服务状态；默认支持的宿主显示具体对话确认，BC内也可核对并同意。本人选择之前不执行；宿主布局仍须验收。模型写用户同意无效。服务接受不等于设备完成；用read_native_command_status核对。item创建仅todo；长期事项只放下不删。日记只create/update正文、心情和标签，entryDate只用于创建，修改前read_native_journal取得revision，照片/日期/格式不改，推断不能写成用户感受。timer支持start/pause/resume/finish，与BC按钮共用session；非start需要sessionId与整数expectedRevision，start可带relatedRecordId。默认计时按用户按钮确认的BC服务时刻生效，仅明确补记过去时间时传effectiveAt并在卡片显示让用户确认；设备离线不自动暂停；结束计时不完成事项。reminder为普通系统通知，非保证叫醒的闹钟：schedule/update需reminderId及完整title/body/fireAt/sound/experiment（合成测试true）；update/cancel须原expectedRevision，先read_native_reminders核对。普通提醒需要独立权限及本人批准，只由指定设备排程，不在所有端重复响。改期/取消须等设备系统回执；设备离线时旧计划仍可能触发，不能因服务接受就说已取消。所有请求时间使用UTC毫秒ISO格式。",inputSchema:object({version:{type:"integer",enum:[1]},commandId:nativeUUIDSchema,deviceId:string,kind:{type:"string",enum:["item","alarm","journal","timer","reminder"]},action:{type:"string",enum:["create","update","delete","restore","schedule","cancel","start","pause","resume","finish"]},recordId:nativeUUIDSchema,sessionId:string,relatedRecordId:string,effectiveAt:string,expectedRevision:{type:["string","integer"]},patch:object({title:string,note:string,status:{type:"string",enum:["active","done","shelved"]},body:string,mood:{type:["string","null"]},tags:{type:"array",items:string,maxItems:30}}),entryDate:string,fireAt:string,title:string,reminderId:nativeUUIDSchema,body:string,sound:{type:"boolean"},experiment:{type:"boolean"},alarmId:nativeUUIDSchema,occurredAt:string,expiresAt:string,userRequest:string},["version","commandId","deviceId","kind","action","occurredAt","userRequest"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"read_native_reminders",outputSchema:nativeCommandOutputSchema,description:"从指定BC设备查询普通提醒及实际系统排程状态；需要独立reminder.read权限，不启动提醒、不申请权限。固定UUID commandId；先返回queued，之后read_native_command_status取实际记录。修改/取消前查询reminderId并includeCancelled=true取得revision。hasMore时用相同筛选和nextCursor、新commandId读取下一页；快照版本改变重读第一页。设备离线/失败不是没有提醒；system_schedule_verified不代表已送达或用户看到。",inputSchema:object({commandId:nativeUUIDSchema,deviceId:string,query:object({reminderId:nativeUUIDSchema,includeCancelled:{type:"boolean"},limit:{type:"integer",minimum:1,maximum:20},cursor:string})},["commandId","deviceId"]),annotations:{readOnlyHint:true,idempotentHint:true}},
  {name:"read_native_journal",outputSchema:nativeCommandOutputSchema,description:"从指定BC设备读取保存的日记文字及照片引用，需要独立journal.read权限。固定UUID格式commandId（不可用任务名或日期拼接）；首次返回queued等设备，之后read_native_command_status取实际页结果。读取不需写入确认，不改日记/计时/通知；query时间是entry.date的[start,end)。返回正文完整、hasMore时相同范围加nextCursor重新请求一页并用新的commandId；版本改变必须重读第一页。照片二进制未读取，不能称看过图片。设备离线或失败不是没有日记。",inputSchema:object({commandId:nativeUUIDSchema,deviceId:string,query:object({start:string,end:string,text:string,includeTrash:{type:"boolean"},limit:{type:"integer",minimum:1,maximum:50},cursor:string})},["commandId","deviceId"]),annotations:{readOnlyHint:true,idempotentHint:true}},
  {name:"read_native_command_status",outputSchema:nativeCommandOutputSchema,description:"核对单次BC原生操作真实进展和设备回执。未确认/等待设备/执行中/结果未知不等于成功。不重新执行，不换commandId。",inputSchema:object({commandId:nativeUUIDSchema},["commandId"]),annotations:{readOnlyHint:true},_meta:{ui:{visibility:["model","app"]},"openai/widgetAccessible":true}},
  {name:"approve_native_command",outputSchema:nativeCommandOutputSchema,description:"仅由对话确认卡片的用户按钮提交具体请求确认；需要widget-only凭据。模型不能批准。",inputSchema:object({commandId:nativeUUIDSchema,requestHash:string,token:string},["commandId","requestHash","token"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true},_meta:{ui:{visibility:["app"]},"openai/widgetAccessible":true,"openai/visibility":"private"}},
  {name:"read_research_log",description:"分页读取本轮上线以后真实BC工具调用的参数摘要、原文定位、结果哈希、错误和处理回执。没有日志不等于未调用；外部连接器及私有思维链未捕获。研究原文由本地记录器下载，不上传新服务。",inputSchema:object({afterId:{type:"integer",minimum:0},throughId:{type:"integer",minimum:0},limit:{type:"integer",minimum:1,maximum:100}}),annotations:{readOnlyHint:true}},
  {name:"complete_batch",description:"完整读完事件变化和状态正文后保存有证据的结论、提醒/操作结果及注意力成本，再原子确认本批。readCallIds使用真实工具返回的research.callId；分页读完才允许确认。此工具不会通知、计时或对外写入；reported_sent只是代理报告。无用户反馈记unknown。纠正用supersedes保留原结果。",inputSchema:object({batchId:string,resultId:string,readCallIds:{type:"array",items:string},conclusions:{type:"array",items:{type:"object",properties:{summary:string,sourceClass:{type:"string",enum:["bc_native","connector","user_statement","public","habit","inference"]},confidence:{type:"string",enum:["high","medium","low","unknown"]},rationale:string,evidenceCallIds:{type:"array",items:string},alternatives:{type:"array",items:string}},required:["summary","sourceClass","confidence","rationale","evidenceCallIds","alternatives"],additionalProperties:false}},notification:{type:"object",properties:{channel:{type:"string",enum:["silent","chat","ordinary_notification"]},result:{type:"string",enum:["not_requested","reported_sent","unknown","failed"]}},required:["channel","result"],additionalProperties:false},operation:{type:"object",properties:{kind:{type:"string",enum:["none","task_command"]},commandId:string},required:["kind"],additionalProperties:false},attention:{type:"object",properties:{seconds:{type:"number",minimum:0},basis:{type:"string",enum:["user_report","agent_estimate"]}},additionalProperties:false},supersedes:string},["batchId","resultId","readCallIds","notification","operation"]),annotations:{readOnlyHint:false,destructiveHint:false}},
  {name:"read_pool_records",description:"分页读取BC设备SwiftData中的长期事项、愿望/待办、已完成和已放下目录，包含阶段、完整字段和内容版本。它是带来源/时效的只读副本，不迁移或另存任务真相；不同设备可能尚未同步。默认隐藏回收站，可显式includeTrash。hasMore时以相同筛选及nextCursor继续，分页固定该快照。未上传/读取失败不等于没有事项；改动使用submit_native_command，由用户确认及指定设备核验版本后执行。",inputSchema:object({deviceId:string,zone:{type:"string",enum:["longterm","todo"]},status:{type:"string",enum:["active","done","shelved"]},includeTrash:{type:"boolean"},limit:{type:"integer",minimum:1,maximum:100},cursor:string}),annotations:{readOnlyHint:true}},
  {name:"read_current_state",description:"读取个人状态、来源时效、覆盖和BC计时。事件处理可先includeValues=false读摘要，再用sourceKeys读取所需正文；valuesIncluded=false不是不可读。默认保留旧版完整读取。stale是旧数据，not_received是未上传，不等于无权限。",inputSchema:object({includeValues:{type:"boolean"},sourceKeys:{type:"array",items:string,maxItems:40}}),annotations:{readOnlyHint:true}},
  {name:"read_changes",description:"按游标分页读取完整变化；按发生时间理解补传。响应大小有界，hasMore时继续nextCursor；可设throughId只读到事件的throughChangeId，避免追逐新变化而一直不能结束本批。",inputSchema:object({afterId:{type:"integer",minimum:0},limit:{type:"integer",minimum:1,maximum:100},throughId:{type:"integer",minimum:0}}),annotations:{readOnlyHint:true}},
  {name:"read_observation_history",description:"按 sourceKey 和发生时间查询一个来源的原始历史；保留未知版本和字段，区分发生与接收时间。每页最多100条，hasMore时以相同范围及nextCursor继续；补传后复核需重读完整时间窗。不能把历史当实时状态。",inputSchema:object({sourceKey:string,from:{type:"string",format:"date-time"},before:{type:"string",format:"date-time"},limit:{type:"integer",minimum:1,maximum:100},cursor:string},["sourceKey"]),annotations:{readOnlyHint:true}},
  {name:"read_instructions",description:"读取用户已批准的个人状态助手行为约定。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"task_command",outputSchema:nativeCommandOutputSchema,description:"共享计时的兼容提案入口，与submit_native_command(kind=timer)完全相同，不直接执行。需要主动timer权限、指定设备和本人具体确认（默认BC待确认页面）；不能把provenance=user或模型宣称同意当授权。BC按确认时刻计时；保持同commandId并核对session/revision，结束计时不完成事项。建议使用统一submit_native_command入口。",inputSchema:object({commandId:nativeUUIDSchema,deviceId:string,action:{type:"string",enum:["start","pause","resume","finish"]},title:string,sessionId:string,expectedRevision:{type:"integer",minimum:1},occurredAt:string,expiresAt:string,userRequest:string,relatedRecordId:string,effectiveAt:string},["commandId","deviceId","action","occurredAt","userRequest"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"read_task_history",description:"分页读计时历史。origin=shared（默认）读共享会话；origin=legacy并指定deviceId读新版BC发布的旧SwiftData会话副本，不迁移或创建共享会话。共享空页不代表没有旧记录，两种来源同窗分别查，不自动相加或合并两端；旧设备目录未支持会明确报告。hasMore时保持来源/设备/时间窗及nextCursor读完。",inputSchema:object({origin:{type:"string",enum:["shared","legacy"]},deviceId:string,from:{type:"string",format:"date-time"},before:{type:"string",format:"date-time"},limit:{type:"integer",minimum:1,maximum:100},cursor:{type:"string"}}),annotations:{readOnlyHint:true}},
  {name:"read_task_commands",description:"按服务端保存时间分页读取BC计时原始操作回执与独立deviceReceipts；可按sessionId筛选，读到hasMore=false。设备回执只报告本机计时缓存保存版本，不证明屏幕/灵动岛呈现或人看到。缺失仍unknown，不会重放操作或修改记录。",inputSchema:object({sessionId:{type:"string"},from:{type:"string",format:"date-time"},before:{type:"string",format:"date-time"},limit:{type:"integer",minimum:1,maximum:100},cursor:{type:"string"}}),annotations:{readOnlyHint:true}},
  {name:"acknowledge_batch",description:"仅在读取最新状态、补齐截断变化并完成本批理解后调用，记录 Dot 的实际处理时间；不能提前确认。",inputSchema:object({batchId:string},["batchId"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"record_context",description:"保存用户说明或单独标记的推断；推断必须引用依据，不会自动完成或暂停显式计时。缓存兼容：kind=bc.research.batch_result时body为完整研究结果，转交complete_batch同一校验入口，不新增活动推断。",inputSchema:object({id:string,kind:string,body:{type:"object"},assertion:{type:"string",enum:["user","inferred"]},confidence:{type:"string",enum:["high","medium","low","unknown"]},basis:{type:"array",items:string},expiresAt:{type:"string",format:"date-time"},supersedes:string},["id","kind","body","assertion","confidence","basis"]),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
  {name:"read_connection_status",description:"查看已登记设备、事件订阅与回调接收状态，以及当前请求的MCP原生确认/组件能力声明；不返回密钥。声明不证明界面呈现或本人确认，缺少元数据是未知。",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"flush_minute_changes",description:"发送本分钟尚未发送的变化并重试待发送回调；一分钟最多一个新批次，没有变化不发。不能把回调接收当作 Dot 完成分析。",inputSchema:object(),annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true}},
];
const event={name:"state.minute_changed",description:"按分钟汇总全部有变化的个人状态；先读最新状态，再静默理解，只有必要时问或建议。",delivery:["webhook"],inputSchema:object(),payloadSchema:{type:"object",properties:{schemaVersion:{type:"integer"},readLatestState:{type:"boolean"},fromChangeId:{type:"integer"},throughChangeId:{type:"integer"},changes:{type:"array",items:{type:"object"}},omittedCount:{type:"integer"},decision:{type:"object"}},required:["schemaVersion","readLatestState","fromChangeId","throughChangeId","changes","omittedCount"],additionalProperties:false}};
export async function POST(request:Request){
  let id:unknown=null,methodForLog="unknown";
  try{
    const raw=await request.text();if(new TextEncoder().encode(raw).length>256*1024)throw new BridgeError("请求过大",413);
    const rpc=JSON.parse(raw);id=rpc.id??null;
    const p=rpc.params??{},method=rpc.method;
    if(["initialize","server/discover","tools/list","resources/list","resources/read"].includes(method))
      console.info("state-bridge-mcp-ui-discovery",{method,registeredResource:nativeConfirmationUri,knownResource:method==="resources/read"?p.uri===nativeConfirmationUri:undefined});
    if(["initialize","notifications/initialized","ping","server/discover","tools/list","resources/list","resources/read","events/list","events/subscribe","events/unsubscribe","tools/call"].includes(method))methodForLog=method;
    // MCP 2026-07-28 requires complete/input_required discrimination. Missing
    // resultType can leave UI transport unable to construct a widget even when
    // a legacy data-only client accepts the same content.
    const result=(value:unknown)=>Response.json({jsonrpc:"2.0",id,result:{resultType:"complete",...(value as Record<string,unknown>)}});
    if(method==="initialize")return result({protocolVersion:"2026-07-28",capabilities:{tools:{},events:{},resources:{}},serverInfo:{name:"personal-state-bridge",version:"0.1.0"},instructions:"个人状态数据与持久化计时；先调用 read_instructions。"});
    if(method==="notifications/initialized")return new Response(null,{status:202});
    if(method==="ping")return result({});
    if(method==="server/discover")return result({resultType:"complete",supportedVersions:["2026-07-28"],capabilities:{tools:{},events:{},resources:{}}});
    if(method==="tools/list")return result({tools});
    if(method==="resources/list")return result({resources:[{uri:nativeConfirmationUri,name:"BC 原生操作确认",mimeType:"text/html;profile=mcp-app"}]});
    if(method==="resources/read"){
      if(p.uri!==nativeConfirmationUri)throw new BridgeError("未知UI资源",404);
      return result({contents:[{uri:nativeConfirmationUri,mimeType:"text/html;profile=mcp-app",text:nativeConfirmationHtml,_meta:{ui:{prefersBorder:true,csp:{connectDomains:[],resourceDomains:[]}},"openai/widgetCSP":{connect_domains:[],resource_domains:[]}}}]});
    }
    if(method==="events/list")return result({events:[event]});
    const owner=request.headers.get("oai-authenticated-user-id");
    if(!owner)throw new BridgeError("数据和订阅需要已认证用户身份",401);
    const core=service();
    if(method==="events/subscribe")return result(await core.subscribe(p,owner));
    if(method==="events/unsubscribe")return result(await core.unsubscribe(p,owner));
    if(method==="tools/call"){
      const a=p.arguments??{};
      const cachedPreview=p.name==="record_context"&&a.kind==="bc.confirmation.preview";
      if(p.name==="preview_native_confirmation"||cachedPreview){
        const previewArgs=cachedPreview?a.body:a;
        if(!previewArgs||Object.keys(previewArgs).some(key=>!["commandId","variant"].includes(key)))throw new BridgeError("只读显示测试只接受原commandId和对照类型");
        if(cachedPreview&&(a.id!=="bc-preview:"+previewArgs.commandId||a.assertion!=="user"||a.confidence!=="unknown"||!Array.isArray(a.basis)||a.basis.length||Object.keys(a).some(key=>!["id","kind","body","assertion","confidence","basis"].includes(key))))throw new BridgeError("只读显示测试兼容参数无效；不会保存上下文");
        let inputRequired:unknown=null;
        const value=await core.research.invoke(p.name,{...a,commandId:previewArgs.commandId},owner,async()=>{const preview=await previewNativeForm(core,previewArgs.commandId,owner,p,previewArgs.variant??'boolean');inputRequired=preview.inputRequired;return preview.value??{preview:true,operationEffect:"read_only",executed:false,originalCommandId:previewArgs.commandId,presentationPrepared:true,hostDisplayed:"unknown"};});
        return inputRequired?Response.json({jsonrpc:"2.0",id,result:inputRequired}):result(nativeToolResult(value));
      }
      const proposal=["submit_native_command","task_command"].includes(p.name);
      const hasInput=p.inputResponses!==undefined||p.requestState!==undefined;
      if(hasInput&&!proposal)throw new BridgeError("此工具不接受确认续传");
      const form=core.nativeCommands.policy().defaultConfirmationChannel==="chat_form"&&supportsNativeForm(p)&&proposal;
      const callbackTraceId=crypto.randomUUID();
      let response:any=null;
      if(hasInput)try{response=nativeFormResponse(p);}catch(error){
        await core.research.append("native_confirmation_response_rejected",null,{callbackTraceId,originTool:p.name,stage:(error as any)?.confirmationStage??"response.capabilities",status:error instanceof BridgeError?error.status:500,responseShape:formResponseShape(p.inputResponses?.bc_native_confirmation),inputShape:nativeFormInputShape(p)},owner);
        throw error;
      }
      const submit=async(input:any)=>{
        if(response){
          const references=safeArguments(input);
          const evidence={callbackTraceId,originTool:p.name,commandId:typeof input.commandId==="string"&&new RegExp(nativeUUIDSchema.pattern).test(input.commandId)?input.commandId:null,...await core.nativeCommands.confirmationIdentity(input,owner),expectedRevision:references.expectedRevision??null,sessionId:references.sessionId??null,responseShape:formResponseShape(response),source:"host_response",userGesture:"unknown",cause:"unknown"};
          await core.research.append("native_confirmation_response_received",null,evidence,owner);
          let value;
          try {value=await core.nativeCommands.respondForm({request:input,originTool:p.name,requestState:p.requestState,response},owner);}
          catch(error){await core.research.append("native_confirmation_response_rejected",null,{...evidence,stage:(error as any)?.confirmationStage??"request_binding_or_state",status:error instanceof BridgeError?error.status:500,category:error instanceof BridgeError?"request":"internal"},owner);throw error;}
          await core.research.append("native_confirmation_response_processed",null,{...evidence,state:value.state,grantRevision:value.grantRevision,approvedAt:value.approvedAt,deviceApplication:value.deviceApplication},owner);
          return {value,approval:null};
        }
        return core.nativeCommands.submit(input,owner,{formOrigin:form?p.name:null});
      };
      let approval:unknown=null;
      const loggedArgs=response?{...a,confirmation:{transport:"mcp_form",source:"host_response",userGesture:"unknown",cause:"unknown"}}:a;
      let value=await core.research.invoke(p.name,loggedArgs,owner,async()=>{let value;
      switch(p.name){
        case "read_native_capabilities":value=await core.nativeCommands.capabilities();break;
        case "read_native_reminders":value=await core.nativeCommands.readReminders(a,owner);break;
        case "read_native_journal":value=await core.nativeCommands.readJournal(a,owner);break;
        case "submit_native_command":{const submitted=await submit(a);value=submitted.value;approval=submitted.approval;break;}
        case "approve_native_command":value=await core.nativeCommands.approve(a,owner);break;
        case "read_native_command_status":value=await core.nativeCommands.status(a,owner);break;
        case "read_research_log":value=await core.research.read(a);break;
        case "complete_batch":value=await core.research.complete(a,owner);break;
        case "read_pool_records":value=await core.readPoolRecords(a);break;
        case "read_current_state":value=await core.readState(a);break;
        case "read_changes":value=await core.readChanges(a.afterId??0,a.limit??100,a.throughId??null);break;
        case "read_observation_history":value=await core.readObservationHistory(a);break;
        case "read_instructions":value={instructions:dotInstructions};break;
        case "task_command":{const submitted=await submit({...a,version:1,kind:"timer"});value=submitted.value;approval=submitted.approval;break;}
        case "read_task_history":value=await core.taskHistory(a);break;
        case "read_task_commands":value=await core.readTaskCommands(a);break;
        case "acknowledge_batch":value=await core.acknowledgeBatch(a.batchId,owner);break;
        case "record_context":value=await core.recordContext(a,owner);break;
        case "read_connection_status":value={...await core.diagnostics(),mcpClient:clientConfirmationCapabilities(p)};break;
        case "flush_minute_changes":value=await core.flush();break;
        default:throw new BridgeError("未知工具",404);
      }
      return value;});
      if(form&&!response){
        const finalized=await finalizeNativeForm(core,value,approval,owner,p.name);
        value=finalized.value;approval=finalized.approval;
        if(finalized.inputRequired)return Response.json({jsonrpc:"2.0",id,result:finalized.inputRequired});
      }
      if(proposal&&!response&&core.nativeCommands.policy().defaultConfirmationChannel==="native"){
        // Native approvals use existing target-device authentication. No secret
        // or model-callable authorization is returned as a layout fallback.
        approval=null;
        if(value.state==='awaiting_confirmation'){
          let display:any=null;
          try {display=await confirmationPresentation(core,value);} catch { /* Target BC reads authoritative before values; errors remain visible there. */ }
          value={...value,approvalUI:{channel:'target_device_button',deviceLabel:display?.deviceLabel??'指定设备',title:display?.recordTitle??value.request.title??value.request.patch?.title??'具体改动',expiresAt:value.expiresAt,instructions:'在指定设备 BC 顶部点「待确认」，打开这项请求并核对改动，然后本人同意或拒绝。尚未执行；Dots 不需要等待长条弹窗。'}};
          await core.research.append('native_confirmation_entry_returned',null,{commandId:value.commandId,requestHash:value.requestHash,grantRevision:value.grantRevision,state:value.state,channel:'target_device_button',hostDisplayed:'unknown',deviceApplied:'unknown'},owner);
        }
      }
      return result(nativeToolResult(value,approval));
    }
    return Response.json({jsonrpc:"2.0",id,error:{code:-32601,message:"未知方法"}});
  }catch(error){
    const message=error instanceof BridgeError?error.message:"接口暂不可用，请勿确认操作已完成";
    // Only protocol labels and categorized failures: never arguments, identities,
    // callback URLs, tokens, challenges, or device observations.
    console.warn("state-bridge-mcp-error",{method:methodForLog,kind:error instanceof CallbackEndpointError?"callback":error instanceof BridgeError?"request":"internal",status:error instanceof BridgeError?error.status:500,reason:error instanceof CallbackEndpointError?error.reason:undefined});
    return Response.json({jsonrpc:"2.0",id,error:{code:error instanceof CallbackEndpointError?-32015:error instanceof BridgeError&&error.status===401?-32001:-32602,message,...(error instanceof CallbackEndpointError?{data:{reason:error.reason}}:error instanceof BridgeError&&(error as any).current?{data:{current:(error as any).current}}:{})}}, {status:error instanceof BridgeError&&error.status===401?401:200});
  }
}
