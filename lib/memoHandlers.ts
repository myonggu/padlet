import "server-only";

import { NextResponse } from "next/server";
import { createAdminSession, requireAdmin, revokeAdminSession } from "./adminSession";
import { getEnv } from "./env";
import {
  assertSameOrigin,
  getClientIp,
  HttpError,
  readJsonObject,
  requireUuid,
  toErrorResponse,
} from "./http";
import { isPastelColor, PASTEL_COLORS } from "./memoColors";
import { hashPassword, isFourDigitPassword, verifyPassword } from "./password";
import { consumeRateLimit, releaseRateLimit } from "./rateLimit";
import { getSupabaseAdmin, getSupabaseServerAnon } from "./supabaseAdmin";

export const PUBLIC_MEMO_COLUMNS = "id,title,content,color,position,created_at,updated_at";

// Matches PostgreSQL char_length (code points), not UTF-16 units.
function charLength(value: string) {
  return Array.from(value).length;
}

function readText(value: unknown, label: string, max: number) {
  const text = typeof value === "string" ? value.trim() : "";
  const length = charLength(text);
  if (length < 1 || length > max) {
    throw new HttpError(400, `${label}은(는) 공백을 제외하고 1~${max}자여야 합니다.`);
  }
  return text;
}

function readPassword(value: unknown) {
  if (!isFourDigitPassword(value)) {
    throw new HttpError(400, "비밀번호는 숫자 4자리여야 합니다.");
  }
  return value;
}

export async function listPublicMemos() {
  try {
    const { data, error } = await getSupabaseServerAnon()
      .from("memos")
      .select(PUBLIC_MEMO_COLUMNS)
      .order("created_at", { ascending: false });
    if (error) throw error;
    return NextResponse.json({ memos: data ?? [] });
  } catch (error) {
    return toErrorResponse(error, "GET /api/memos", "메모 목록을 불러오지 못했습니다.");
  }
}

export async function createMemo(request: Request) {
  try {
    assertSameOrigin(request);
    await consumeRateLimit("createMemo", getClientIp(request));

    const body = await readJsonObject(request);
    const title = readText(body.title, "제목", 80);
    const content = readText(body.content, "내용", 2000);
    const password = readPassword(body.password);

    let color: string;
    if (body.color === undefined || body.color === null || body.color === "") {
      color = PASTEL_COLORS[Math.floor(Math.random() * PASTEL_COLORS.length)];
    } else if (isPastelColor(body.color)) {
      color = body.color;
    } else {
      throw new HttpError(400, "허용되지 않은 색상입니다.");
    }

    const passwordHash = await hashPassword(password);
    const { data, error } = await getSupabaseAdmin()
      .rpc("create_memo_with_credentials", {
        p_title: title,
        p_content: content,
        p_password_hash: passwordHash,
        p_color: color,
      })
      .select(PUBLIC_MEMO_COLUMNS);
    if (error) throw error;

    return NextResponse.json({ memo: data }, { status: 201 });
  } catch (error) {
    return toErrorResponse(error, "POST /api/memos", "메모를 저장하지 못했습니다.");
  }
}

export async function deleteMemoWithPassword(request: Request, routeId?: string) {
  try {
    assertSameOrigin(request);
    const ip = getClientIp(request);
    await consumeRateLimit("deleteRequest", ip);

    const body = await readJsonObject(request);
    const id = requireUuid(routeId ?? body.id);
    const password = readPassword(body.password);

    // Counted before bcrypt; a correct password deletes the memo, so only
    // failed attempts can accumulate for this memo/IP pair.
    await consumeRateLimit("deleteFailure", `${id}:${ip}`);

    const supabase = getSupabaseAdmin();
    const { data: credential, error: readError } = await supabase
      .from("memo_credentials")
      .select("password_hash")
      .eq("memo_id", id)
      .maybeSingle();
    if (readError) throw readError;
    if (!credential) throw new HttpError(404, "메모를 찾을 수 없습니다.");

    if (!(await verifyPassword(password, credential.password_hash))) {
      throw new HttpError(403, "삭제 비밀번호가 일치하지 않습니다.");
    }

    const { error: deleteError } = await supabase.from("memos").delete().eq("id", id);
    if (deleteError) throw deleteError;

    return NextResponse.json({ ok: true });
  } catch (error) {
    return toErrorResponse(error, "POST /api/memos/delete", "메모를 삭제하지 못했습니다.");
  }
}

export async function adminLogin(request: Request) {
  try {
    assertSameOrigin(request);
    const adminHash = getEnv("ADMIN_PASSWORD_HASH");
    getEnv("ADMIN_SESSION_SECRET");

    const body = await readJsonObject(request);
    if (typeof body.password !== "string" || body.password.length < 1 || body.password.length > 200) {
      throw new HttpError(400, "관리자 비밀번호를 입력해 주세요.");
    }

    const attemptKey = await consumeRateLimit("adminLoginFailure", getClientIp(request));
    if (!(await verifyPassword(body.password, adminHash))) {
      throw new HttpError(401, "관리자 비밀번호가 일치하지 않습니다.");
    }
    await releaseRateLimit(attemptKey);

    const response = NextResponse.json({ ok: true });
    await createAdminSession(response);
    return response;
  } catch (error) {
    return toErrorResponse(error, "POST /api/admin/login", "관리자 로그인에 실패했습니다.");
  }
}

export async function adminLogout(request: Request) {
  try {
    assertSameOrigin(request);
    const response = NextResponse.json({ ok: true });
    await revokeAdminSession(response);
    return response;
  } catch (error) {
    return toErrorResponse(error, "POST /api/admin/logout", "로그아웃하지 못했습니다.");
  }
}

export async function adminListMemos() {
  try {
    await requireAdmin();
    const { data, error } = await getSupabaseAdmin()
      .from("memos")
      .select(PUBLIC_MEMO_COLUMNS)
      .order("created_at", { ascending: false });
    if (error) throw error;
    return NextResponse.json({ memos: data ?? [] });
  } catch (error) {
    return toErrorResponse(error, "GET /api/admin/memos", "메모 목록을 불러오지 못했습니다.");
  }
}

export async function adminDeleteMemo(request: Request, routeId?: string) {
  try {
    assertSameOrigin(request);
    await requireAdmin();

    let id = routeId;
    if (id === undefined) id = (await readJsonObject(request)).id as string | undefined;
    const memoId = requireUuid(id);

    const { error } = await getSupabaseAdmin().from("memos").delete().eq("id", memoId);
    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    return toErrorResponse(error, "POST /api/admin/delete", "메모를 강제 삭제하지 못했습니다.");
  }
}

export async function adminDeleteAll(request: Request) {
  try {
    assertSameOrigin(request);
    await requireAdmin();

    const { error } = await getSupabaseAdmin().from("memos").delete().not("id", "is", null);
    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    return toErrorResponse(error, "POST /api/admin/delete-all", "전체 메모를 삭제하지 못했습니다.");
  }
}
