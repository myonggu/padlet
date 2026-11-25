import { adminDeleteMemo } from "@/lib/memoHandlers";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

export async function DELETE(request: Request, { params }: Context) {
  const { id } = await params;
  return adminDeleteMemo(request, id);
}

export async function POST(request: Request, { params }: Context) {
  const { id } = await params;
  return adminDeleteMemo(request, id);
}