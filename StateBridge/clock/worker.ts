/** Independent clock: no model invocation, no raw device data, no public API. */
export interface Env { STATE_BRIDGE_ORIGIN:string; STATE_BRIDGE_PLATFORM_TOKEN:string; STATE_BRIDGE_DEVICE_TOKEN:string }
export default {
  async scheduled(_event:ScheduledController,env:Env,ctx:ExecutionContext){
    ctx.waitUntil(flush(env));
  },
  async fetch(){return new Response('Clock has no public control endpoint.',{status:404});},
};
async function flush(env:Env){
  const origin=new URL(env.STATE_BRIDGE_ORIGIN);
  if(origin.protocol!=='https:'||origin.hostname!=='jason-state-bridge.jason25417.chatgpt.site'||origin.pathname!=='/')throw new Error('Clock origin must be the approved private state service.');
  const response=await fetch(new URL('/api/flush',origin),{method:'POST',redirect:'manual',signal:AbortSignal.timeout(25000),headers:{'Content-Type':'application/json','OAI-Sites-Authorization':'Bearer '+env.STATE_BRIDGE_PLATFORM_TOKEN,'Authorization':'Bearer '+env.STATE_BRIDGE_DEVICE_TOKEN},body:'{}'});
  if(!response.ok)throw new Error('Minute flush failed with HTTP '+response.status);
  // Print only transport counts. Do not log secrets, callbacks, or observations.
  const receipt=await response.json() as {minute:number;batchId:string|null;delivered:number;activeSubscriptions:number};
  console.log(JSON.stringify({minute:receipt.minute,batchCreated:!!receipt.batchId,delivered:receipt.delivered,activeSubscriptions:receipt.activeSubscriptions}));
}
