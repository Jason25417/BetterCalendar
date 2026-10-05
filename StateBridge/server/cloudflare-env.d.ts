declare namespace Cloudflare {
  interface Env {
    STATE_BRIDGE_SERVICE_TOKEN?: string;
    STATE_BRIDGE_ORIGIN?: string;
    DB?: D1Database;
    BUCKET?: R2Bucket;
  }
}
