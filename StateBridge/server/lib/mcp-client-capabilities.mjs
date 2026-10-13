// Inspect only standard declarations on this request. Never retain raw _meta,
// client identity, credentials, extension settings or host-private state.
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
export function clientConfirmationCapabilities(params = {}) {
  const meta = object(params._meta) ? params._meta : {};
  const raw = meta['io.modelcontextprotocol/clientCapabilities'];
  const declared = object(raw);
  const elicitation = declared && object(raw.elicitation) ? raw.elicitation : null;
  // The standard also defines elicitation:{} as implicit form-only support.
  const form = !declared ? 'unknown' : !elicitation ? 'not_declared'
    : object(elicitation.form) ? 'declared_explicit'
    : !own(elicitation, 'form') && !own(elicitation, 'url') && Object.keys(elicitation).length === 0 ? 'declared_implicit'
    : 'not_declared';
  const ui = declared && object(raw.extensions) && object(raw.extensions['io.modelcontextprotocol/ui']);
  const protocol = meta['io.modelcontextprotocol/protocolVersion'];
  return {
    version: 1, scope: 'current_request_only',
    protocolVersion: typeof protocol === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(protocol) ? protocol : 'unknown',
    capabilities: declared ? 'declared' : own(meta, 'io.modelcontextprotocol/clientCapabilities') ? 'malformed' : 'missing',
    form, ui: !declared ? 'unknown' : ui ? 'declared' : 'not_declared',
    rendering: 'unverified', humanConfirmation: 'unverified',
    interpretation: 'Host declarations are not evidence that a person saw or confirmed a request. Missing metadata is unknown, not proof that Dots cannot support it.',
  };
}
