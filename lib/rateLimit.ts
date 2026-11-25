import "server-only";

import { createHmac } from "node:crypto";
import { getEnv } from "./env";
import { HttpError } from "./http";
import { getSupabaseAdmin } from "./supabaseAdmin";

export const RATE_LIMITS = {
  createMemo: { limit: 20, windowSeconds: 10 * 60 },
  deleteRequest: { limit: 30, windowSeconds: 10 * 60 },
  deleteFailure: { limit: 5, windowSeconds: 10 * 60 },
  adminLoginFailure: { limit: 5, windowSeconds: 15 * 60 },
} as const;

export type RateLimitName = keyof typeof RATE_LIMITS;

// Raw IPs are never stored; buckets are keyed by an HMAC of the identifier.
function bucketKey(name: RateLimitName, identifier: string) {
  const derived = createHmac("sha256", getEnv("ADMIN_SESSION_SECRET"))
    .update("mindlet-rate-limit-v1")
    .digest();
  const digest = createHmac("sha256", derived)
    .update(`${name}:${identifier}`)
    .digest("base64url");
  return `${name}:${digest}`;
}

/**
 * Atomically counts one attempt in a fixed window (Supabase RPC, row-locked
 * upsert). Throws 429 when exceeded and 503 when the store is unavailable, so
 * the protected operation never runs without a successful check.
 */
export async function consumeRateLimit(name: RateLimitName, identifier: string) {
  const { limit, windowSeconds } = RATE_LIMITS[name];
  const key = bucketKey(name, identifier);
  const { data, error } = await getSupabaseAdmin().rpc("consume_rate_limit", {
    p_key: key,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });

  if (error || typeof data !== "boolean") {
    console.error(`[rate-limit:${name}] 저장소 오류 (code: ${error?.code ?? "invalid"})`);
    throw new HttpError(503, "잠시 후 다시 시도해 주세요.");
  }
  if (!data) {
    throw new HttpError(429, "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.", {
      "Retry-After": String(windowSeconds),
    });
  }
  return key;
}

/** Gives back one counted attempt (e.g. after a successful admin login). */
export async function releaseRateLimit(key: string) {
  const { error } = await getSupabaseAdmin().rpc("release_rate_limit", { p_key: key });
  if (error) console.error(`[rate-limit] 반환 실패 (code: ${error.code})`);
}
