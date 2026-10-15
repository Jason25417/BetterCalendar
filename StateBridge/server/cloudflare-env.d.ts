declare namespace Cloudflare {
  interface Env {
    STATE_BRIDGE_SERVICE_TOKEN?: string;
    STATE_BRIDGE_ORIGIN?: string;
    BC_APPROVAL_TTL_SECONDS?: string;
    BC_CONFIRMATION_CHANNEL?: 'native' | 'chat_form';
    DB?: D1Database;
    BUCKET?: R2Bucket;
  }
}
