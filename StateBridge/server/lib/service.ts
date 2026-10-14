import { env } from "cloudflare:workers";
import { createBridge } from "./bridge.mjs";
export function service() {
  if (!env.DB) throw new Error("状态数据库尚未就绪");
  return createBridge(env.DB,{approvalTTLSeconds:env.BC_APPROVAL_TTL_SECONDS===undefined?86400:Number(env.BC_APPROVAL_TTL_SECONDS),confirmationChannel:env.BC_CONFIRMATION_CHANNEL??"native"});
}
