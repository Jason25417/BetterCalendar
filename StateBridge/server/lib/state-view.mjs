const errorStatuses = new Set(["read-unavailable", "permission-request-failed", "location-unavailable", "notification-unavailable", "history-directory-unavailable", "folder-selection-failed", "permission-or-browser-unavailable", "unavailable"]);
const emptyStatuses = new Set(["not-frontmost"]);

// Preserve full observations; a diagnostic clock alone is not a new activity
// or step delta. Unknown fields still participate in change detection.
export function observationSignalValue(source,value) {
  if(!value||Array.isArray(value)||typeof value!=='object')return value;
  const omit=source==='mac.activity'?['inputIdleSeconds','foregroundChanged']:source==='health.steps'?['windowEnd','queriedAt']:[];
  return Object.fromEntries(Object.entries(value).filter(([key])=>!omit.includes(key)));
}

// Keep availability and freshness independent. A fresh error is not usable
// evidence; an old successful observation is history, not the current activity.
export function sourceView(observation, sourceKey, readAt) {
  const value = observation.value;
  const reason = value && !Array.isArray(value) && typeof value === "object" ? value.availability : null;
  let availability = "available";
  if (reason === "not-configured") availability = "not_configured";
  else if (reason === "not-authorized") availability = "not_authorized";
  else if (errorStatuses.has(reason)) availability = "error";
  else if (reason === "partial") availability = "partial";
  else if (reason === "no-readable-samples-not-proof-of-no-sleep" || reason === "no-readable-samples-not-proof-of-no-steps" || reason === "no-visible-home-or-permission") availability = "unknown";
  else if (emptyStatuses.has(reason)) availability = "empty";
  else if (Array.isArray(value) && !value.length) availability = observation.source.startsWith("health.") ? "unknown" : "empty";
  else if (value && typeof value === "object" && observation.source === "health.steps" && value.count == null) availability = "unknown";
  else if (value && !Array.isArray(value) && typeof value === "object" && observation.source === "health.resting-heart-rate" && value.bpm == null) availability = "unknown";
  else if (["available", "partial"].includes(availability) && value && typeof value === "object" && (Array.isArray(value.items) || Array.isArray(value.samples))) {
    const entries = value.items ?? value.samples;
    if (availability === "partial" || value.truncated || value.omittedItems) availability = "partial";
    else if (!entries.length) availability = observation.source.startsWith("health.") ? "unknown" : "empty";
  }
  const freshness = observation.expiresAt && Date.parse(observation.expiresAt) <= Date.parse(readAt) ? "stale" : "current";
  const observed = Date.parse(observation.observedAt), received = Date.parse(observation.receivedAt), read = Date.parse(readAt);
  const observationAgeSeconds = Number.isFinite(observed)&&Number.isFinite(read)?Math.max(0,(read-observed)/1000):null;
  const deliveryDelaySeconds = Number.isFinite(observed)&&Number.isFinite(received)?Math.max(0,(received-observed)/1000):null;
  return {
    ...observation, sourceKey, freshness, availability,
    observationAgeSeconds,deliveryDelaySeconds,freshnessMeaning:'content_expiry_not_continuous_sampling',
    collectionRecency:observationAgeSeconds===null?'unknown':observationAgeSeconds<=300?'recent':'older_than_5_minutes',
    reason: reason ?? (availability === "unknown" ? "empty_samples_do_not_establish_absence_or_permission" : null),
    lastObservedAt: observation.observedAt, lastReceivedAt: observation.receivedAt,
    lastSuccessfulReadAt: ["available", "partial", "empty"].includes(availability) ? observation.observedAt : null,
    dataRole: observation.source === "bc.pool.chunk" ? "record-fragment" : "source-data",
    usableForCurrentState: observation.source !== "bc.pool.chunk" && freshness === "current" && ["available", "partial", "empty"].includes(availability),
  };
}

export function coverageView(devices, sources) {
  const byKey = new Map(sources.map(s => [s.sourceKey, s]));
  return devices.map(d => ({
    deviceId: d.id, label: d.label, revoked: d.revoked_at != null,
    sources: [...JSON.parse(d.scopes), ...(JSON.parse(d.scopes).includes("user.context") ? ["bc.pool"] : [])].filter((s, i, a) => s !== "bridge.probe" && a.indexOf(s) === i).map(source => {
      const state = byKey.get(`${d.id}:${source}`);
      return { source, availability: state?.availability ?? "not_received", freshness: state?.freshness ?? "unknown", usableForCurrentState: state?.usableForCurrentState ?? false, lastObservedAt: state?.lastObservedAt ?? null, lastReceivedAt: state?.lastReceivedAt ?? null };
    }),
  }));
}

export function stateWarnings(sources) {
  return sources.filter(s => s.source === "health.status" && s.availability === "error").flatMap(status => {
    const later = sources.filter(s => s.deviceId === status.deviceId && s.source.startsWith("health.") && s.source !== "health.status" && s.usableForCurrentState && Date.parse(s.observedAt) > Date.parse(status.observedAt));
    return later.length ? [{ code: "health_summary_older_than_samples", deviceId: status.deviceId, sourceKeys: later.map(s => s.sourceKey), explanation: "旧健康汇总失败不代表较新的各项数据不可读取；分别使用各来源的新鲜度。" }] : [];
  });
}
