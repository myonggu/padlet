export const PASTEL_COLORS = [
  "#fef3c7",
  "#dbeafe",
  "#dcfce7",
  "#fce7f3",
  "#f3e8ff",
  "#fed7aa",
  "#e0f2fe",
  "#fae8ff",
] as const;

export type PastelColor = (typeof PASTEL_COLORS)[number];

export function isPastelColor(value: unknown): value is PastelColor {
  return typeof value === "string" && (PASTEL_COLORS as readonly string[]).includes(value);
}
