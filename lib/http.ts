import "server-only";

import { NextResponse } from "next/server";
import { ConfigError } from "./env";

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    message: string,
    public readonly headers?: Record<string, string>,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

export function requireUuid(value: unknown) {
  if (!isUuid(value)) throw new HttpError(400, "잘못된 메모 ID입니다.");
  return value.toLowerCase();
}

export async function readJsonObject(request: Request): Promise<Record<string, unknown>> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    throw new HttpError(400, "잘못된 JSON 요청입니다.");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new HttpError(400, "잘못된 JSON 요청입니다.");
  }
  return body as Record<string, unknown>;
}

/**
 * CSRF defence for every state-changing API.
 *
 * `request.url` is built by Next.js, not taken from client-controlled
 * forwarding headers: locally it uses the server's own hostname/port, and on
 * Vercel (`experimental.trustHostHeader` is enabled automatically) it uses the
 * `host` that Vercel routed to this deployment. Browsers always send `Origin`
 * on cross-origin and same-origin POST/DELETE fetches, so a missing or
 * different Origin is rejected.
 */
export function assertSameOrigin(request: Request) {
  const origin = request.headers.get("origin");
  if (!origin || origin === "null") {
    throw new HttpError(403, "허용되지 않은 요청입니다.");
  }
  let expected: string;
  let received: string;
  try {
    expected = new URL(request.url).origin;
    received = new URL(origin).origin;
  } catch {
    throw new HttpError(403, "허용되지 않은 요청입니다.");
  }
  if (expected !== received) {
    throw new HttpError(403, "허용되지 않은 요청입니다.");
  }
}

/**
 * Client IP for rate limiting.
 *
 * On Vercel the edge overwrites `x-forwarded-for` / `x-real-ip` and sets
 * `x-vercel-forwarded-for`, so client-supplied values cannot spoof them
 * (https://vercel.com/docs/headers/request-headers). Outside Vercel those
 * headers are client-controlled, so all requests share one local bucket.
 */
export function getClientIp(request: Request) {
  if (process.env.VERCEL !== "1") return "local";
  const raw =
    request.headers.get("x-vercel-forwarded-for") ??
    request.headers.get("x-real-ip") ??
    request.headers.get("x-forwarded-for") ??
    "";
  const ip = raw.split(",")[0]?.trim();
  return ip || "unknown";
}

export function toErrorResponse(error: unknown, context: string, fallback: string) {
  if (error instanceof HttpError) {
    return NextResponse.json(
      { error: error.message },
      { status: error.status, headers: error.headers },
    );
  }
  if (error instanceof ConfigError) {
    console.error(`[${context}] ${error.message}`);
    return NextResponse.json(
      { error: "서버 설정을 확인해 주세요. 관리자에게 문의하세요." },
      { status: 500 },
    );
  }
  const code =
    typeof error === "object" && error !== null && "code" in error
      ? String((error as { code: unknown }).code)
      : "unknown";
  const message =
    typeof error === "object" && error !== null && "message" in error
      ? String((error as { message: unknown }).message).slice(0, 200)
      : "";
  console.error(`[${context}] 처리 실패 (code: ${code}) ${message}`.trim());
  return NextResponse.json({ error: fallback }, { status: 500 });
}
