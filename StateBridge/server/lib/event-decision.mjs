// The transport owns deduplication and minute batching; this seam owns only
// whether the resulting batch should be handed to the single reasoning agent.
export class EventDecisionPolicy {
  async decide(_batch) { throw new Error("EventDecisionPolicy.decide must be implemented"); }
}

export class ForwardAllToDots extends EventDecisionPolicy {
  async decide({ changes }) {
    return { forward: changes.length > 0, policy: "ForwardAllToDots", reason: "delegate_to_dots" };
  }
}
