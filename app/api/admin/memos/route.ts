import { adminDeleteAll, adminListMemos } from "@/lib/memoHandlers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function GET() {
  return adminListMemos();
}

export function DELETE(request: Request) {
  return adminDeleteAll(request);
}

export function POST(request: Request) {
  return adminDeleteAll(request);
}