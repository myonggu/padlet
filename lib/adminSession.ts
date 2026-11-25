import "server-only";

import { createHmac, randomBytes } from "node:crypto";
import { cookies } from "next/headers";
import type { NextResponse } from "next/server";
import { getEnv } from "./env";
import { HttpError } from "./http";
import { getSupabaseAdmin } from "./supabaseAdmin";

export const ADMIN_COOKIE = "mindlet_admin";
export const ADMIN_SESSION_SECONDS = 60 * 60 * 8;

function tokenDigest(token: string) {
  return createHmac("sha256", getEnv("ADMIN_SESSION_SECRET"))
    .update(`mindlet-admin-session-v1:${token}`)
    .digest("hex");
}

function cookieOptions(maxAge: number) {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "strict" as const,
    path: "/",
    maxAge,
  };
}

/** Creates a random session token; only its HMAC and expiry are stored. */
export async function createAdminSession(response: NextResponse) {
  const token = randomBytes(32).toString("base64url");
  const expiresAt = new Date(Date.now() + ADMIN_SESSION_SECONDS * 1000);
  const supabase = getSupabaseAdmin();

  const { error } = await supabase
    .from("admin_sessions")
    .insert({ token_hmac: tokenDigest(token), expires_at: expiresAt.toISOString() });
  if (error) throw error;

  await supabase.from("admin_sessions").delete().lt("expires_at", new Date().toISOString());

  response.cookies.set(ADMIN_COOKIE, token, cookieOptions(ADMIN_SESSION_SECONDS));
}

async function readToken() {
  const token = (await cookies()).get(ADMIN_COOKIE)?.value;
  return token && /^[A-Za-z0-9_-]{43}$/.test(token) ? token : null;
}

/** Server-side check of the session cookie against the stored HMAC and expiry. */
export async function isAdminRequest() {
  const token = await readToken();
  if (!token) return false;

  const { data, error } = await getSupabaseAdmin()
    .from("admin_sessions")
    .select("expires_at")
    .eq("token_hmac", tokenDigest(token))
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();

  if (error) throw error;
  return Boolean(data);
}

export async function requireAdmin() {
  if (!(await isAdminRequest())) {
    throw new HttpError(401, "관리자 인증이 필요합니다.");
  }
}

export async function revokeAdminSession(response: NextResponse) {
  const token = await readToken();
  if (token) {
    const { error } = await getSupabaseAdmin()
      .from("admin_sessions")
      .delete()
      .eq("token_hmac", tokenDigest(token));
    if (error) throw error;
  }
  response.cookies.set(ADMIN_COOKIE, "", cookieOptions(0));
}
