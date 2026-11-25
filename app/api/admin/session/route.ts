import { NextResponse } from "next/server";
import { isAdminRequest } from "@/lib/adminSession";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    return NextResponse.json({ isAdmin: await isAdminRequest() });
  } catch {
    console.error("[GET /api/admin/session] 세션 확인 실패");
    return NextResponse.json({ isAdmin: false });
  }
}