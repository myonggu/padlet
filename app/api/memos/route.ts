import { createMemo, listPublicMemos } from "@/lib/memoHandlers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function GET() {
  return listPublicMemos();
}

export function POST(request: Request) {
  return createMemo(request);
}