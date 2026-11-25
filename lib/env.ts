import "server-only";

export class ConfigError extends Error {
  constructor(
    public readonly variable: string,
    public readonly hint: string,
  ) {
    super(`환경 변수 ${variable} 설정 오류: ${hint}`);
    this.name = "ConfigError";
  }
}

const BCRYPT_HASH = /^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/;

const validators = {
  NEXT_PUBLIC_SUPABASE_URL: (value: string) => {
    try {
      const url = new URL(value);
      const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
      if (url.protocol === "https:" || (local && url.protocol === "http:")) return null;
    } catch {}
    return "https://YOUR_PROJECT.supabase.co 형식의 프로젝트 URL을 입력하세요.";
  },
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: (value: string) =>
    value.startsWith("sb_publishable_")
      ? null
      : "Supabase 대시보드 → Project Settings → API Keys의 Publishable key(sb_publishable_...)를 입력하세요.",
  SUPABASE_SECRET_KEY: (value: string) =>
    value.startsWith("sb_secret_")
      ? null
      : "Supabase 대시보드 → Project Settings → API Keys의 Secret key(sb_secret_...)를 입력하세요.",
  ADMIN_PASSWORD_HASH: (value: string) =>
    BCRYPT_HASH.test(value)
      ? null
      : "bcrypt 해시가 아닙니다. `npm run hash-admin-password`로 생성하세요. .env.local에서는 $ 문자를 \\$로 이스케이프해야 합니다.",
  ADMIN_SESSION_SECRET: (value: string) =>
    value.length >= 32
      ? null
      : "32자 이상의 무작위 문자열이어야 합니다. README의 생성 명령을 사용하세요.",
} as const;

export type EnvName = keyof typeof validators;

export function getEnv(name: EnvName): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new ConfigError(name, "값이 비어 있습니다. .env.local 또는 Vercel 환경 변수에 등록하세요.");
  }
  const problem = validators[name](value);
  if (problem) throw new ConfigError(name, problem);
  return value;
}
