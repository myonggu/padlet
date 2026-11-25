import { adminDeleteAll } from "@/lib/memoHandlers";

export const runtime = "nodejs";

export function POST(request: Request) {
  return adminDeleteAll(request);
}