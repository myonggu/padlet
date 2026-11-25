# MINDLET

Next.js(App Router) · Supabase · Vercel 기반의 단일 메모 보드입니다. 주소를 아는 사람은 누구나 메모를 조회·작성할 수 있고, 작성자는 숫자 4자리 암호로 자기 메모를 삭제하며, 관리자는 별도 로그인 후 메모를 강제 삭제할 수 있습니다.

## 1. 실행 환경

- Node.js 22 이상 (검증 환경: Node.js v26.13.1, npm 11.20.0)
- 의존성은 `package-lock.json` 기준으로 설치합니다.

```bash
node -v
npm -v
npm ci
```

> Windows PowerShell에서 `npm.ps1` 실행 정책 오류가 나면 `npm.cmd ci`처럼 `.cmd`를 붙여 실행하세요.

## 2. 환경 변수

`.env.example`을 `.env.local`로 복사한 뒤 값을 채웁니다. `.env.local`은 `.gitignore`로 버전 관리에서 제외되어 있습니다.

```bash
cp .env.example .env.local        # Windows: copy .env.example .env.local
```

| 변수 | 용도 | 노출 범위 |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase 프로젝트 URL | 브라우저 |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | 공개 조회용 Publishable key (`sb_publishable_...`) | 브라우저 |
| `SUPABASE_SECRET_KEY` | 서버 작업용 Secret key (`sb_secret_...`) | 서버 전용 |
| `ADMIN_PASSWORD_HASH` | 관리자 암호 bcrypt 해시 | 서버 전용 |
| `ADMIN_SESSION_SECRET` | 관리자 세션 토큰 HMAC 키 (32자 이상) | 서버 전용 |

- 레거시 `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`는 사용하지 않습니다.
- 서버 전용 값에는 절대 `NEXT_PUBLIC_` 접두사를 붙이지 마세요.
- 값이 없거나 형식이 틀리면 서버는 비밀값을 출력하지 않고 변수 이름과 해결 방법만 로그에 남기며, API는 일반 오류(503)를 반환합니다.

### 관리자 암호 해시 생성

```bash
npm run hash-admin-password -- "8자 이상 관리자 암호"
```

두 가지 형태가 출력됩니다.

- **Vercel 대시보드**: 원본 해시(`$2b$12$...`)를 그대로 입력합니다.
- **`.env.local`**: Next.js가 `$`를 변수 확장으로 해석하므로 `\$`로 이스케이프된 줄을 사용합니다.

### 관리자 세션 비밀값 생성

```bash
npm run gen-session-secret
```

출력된 64자 무작위 문자열을 `ADMIN_SESSION_SECRET`에 넣습니다. 관리자 암호 해시를 대신 사용하지 마세요.

## 3. 데이터베이스(SQL) 선택

Supabase 대시보드 → SQL Editor에서 실행합니다.

| 상황 | 실행할 파일 |
| --- | --- |
| 새 빈 DB | `schema.sql` |
| 기존 MINDLET/PADLET DB (`memos.password_hash` 존재 등) | `migration_precheck.sql` 확인 → 백업 → `migration.sql` |

### 신규 DB: `schema.sql`

- `memos`, `memo_credentials`, `admin_sessions`, `rate_limits` 테이블과 RPC, RLS, GRANT를 생성합니다.
- 샘플 데이터는 넣지 않습니다.
- 기존 `memos` 테이블이 이 스키마와 다르면 실행을 중단하고 `migration.sql`을 안내합니다.
- 마지막 검증 블록이 권한·정책을 확인하고 문제가 있으면 오류를 냅니다.

### 기존 DB: `migration.sql` 적용 전제조건

1. `migration_precheck.sql`을 먼저 실행해 현재 컬럼, 제약, 정책, 권한, 함수와 해시 상태를 확인합니다(읽기 전용).
2. 다음을 확인합니다.
   - `memos` 테이블이 존재하고 `id`가 UUID입니다.
   - `password_hash` 값이 모두 bcrypt 형식(`$2a$`/`$2b$`/`$2y$`)입니다. 아니면 마이그레이션이 중단됩니다.
   - 다른 앱이 같은 `memos` 테이블이나 `create_memo_with_credentials` 함수를 사용하지 않습니다.
3. Supabase 백업(또는 `pg_dump`)을 받아 둡니다.
4. `migration.sql`을 실행합니다. 하나의 트랜잭션으로 동작하며 실패하면 전체가 롤백됩니다.

마이그레이션 동작:

- 메모 ID, 제목, 내용, 색상, `created_at`, `updated_at`을 보존합니다. 트리거가 `updated_at`을 덮어쓰지 않도록 순서를 조정했습니다.
- 기존 `memos.password_hash`를 `memo_credentials`로 이전하고, 누락·중복·불일치를 검증한 뒤 공개 테이블에서 해시 컬럼을 제거합니다.
- 기존 정책을 모두 제거하고 공개 조회 정책 하나만 다시 만듭니다. 앱 테이블과 함수의 권한만 회수·부여하며, `public` 스키마 전체 권한은 변경하지 않습니다.

## 4. 로컬 실행

```bash
npm run dev
```

브라우저에서 **http://localhost:3000** 으로 접속합니다. 상태 변경 API는 Origin을 요청 URL과 비교하므로, `127.0.0.1:3000`처럼 다른 호스트명으로 접속하면 작성·삭제가 403으로 거부됩니다.

검증 명령:

```bash
npm run lint
npx tsc --noEmit
npm run build
```

## 5. Vercel 배포

1. 저장소를 Vercel 프로젝트에 연결합니다(Framework: Next.js, 기본 빌드 설정).
2. Project Settings → Environment Variables에 위 **다섯 개** 변수를 Production과 Preview에 등록합니다.
   - `ADMIN_PASSWORD_HASH`는 이스케이프하지 않은 원본 해시를 입력합니다.
   - `SUPABASE_SECRET_KEY`, `ADMIN_PASSWORD_HASH`, `ADMIN_SESSION_SECRET`은 Sensitive로 지정하는 것을 권장합니다.
3. 배포 후 다음을 확인합니다.
   - 목록 조회
   - 메모 작성과 삭제
   - 틀린 암호로 삭제 시 거부
   - 관리자 로그인, 개별 삭제, 전체 삭제, 로그아웃

빌드는 환경 변수 없이도 통과합니다(런타임에 검사). 빌드를 위해 가짜 키를 코드에 넣지 마세요.

## 6. 보안 구조

- **조회**: 브라우저가 Publishable key로 `memos`의 공개 컬럼(`id,title,content,color,position,created_at,updated_at`)만 조회합니다.
- **작성·삭제·관리자 작업**: 서버 API(Node.js Runtime)가 처리합니다.
  - `lib/supabaseAdmin.ts`는 `server-only`이며 Secret key를 사용합니다.
  - 클라이언트는 `persistSession: false`, `autoRefreshToken: false`로 설정되어 있고 사용자 세션을 결합하지 않습니다.
- **작성자 암호**:
  - bcrypt 해시가 비공개 테이블 `memo_credentials`에 저장됩니다.
  - 메모와 해시는 RPC `create_memo_with_credentials`로 한 트랜잭션에 저장되며, 메모를 삭제하면 해시도 함께 삭제됩니다(CASCADE).
- **RLS·권한**:
  - 앱 테이블 4개 모두 RLS가 켜져 있습니다.
  - `anon`/`authenticated`에는 `memos` 공개 컬럼 SELECT만 허용합니다.
  - 비공개 테이블은 정책 없이 권한을 회수했습니다.
  - RPC는 `service_role`만 실행할 수 있습니다.
  - 모든 함수는 `SECURITY INVOKER`이며 `search_path=''`로 고정됩니다.
- **관리자 세션**:
  - 무작위 토큰을 쿠키로 발급하고, DB에는 `HMAC-SHA256(ADMIN_SESSION_SECRET, token)`과 만료시간(8시간)만 저장합니다.
  - 모든 관리자 요청마다 세션을 확인하며, 로그아웃 시 DB 세션을 삭제하고 쿠키를 제거합니다.
  - 쿠키 속성: `HttpOnly`, `SameSite=Strict`, `Path=/`, 프로덕션에서 `Secure`.
- **Origin 검사**:
  - 모든 상태 변경 API는 `new URL(request.url).origin`과 `Origin` 헤더가 정확히 일치해야 합니다. 없거나 다르면 403을 반환합니다.
  - 클라이언트가 보낸 `Host`나 `X-Forwarded-*` 헤더로 허용 주소를 만들지 않으며, 주소 설정용 환경 변수도 없습니다.
- **클라이언트 IP**:
  - Vercel에서는 플랫폼이 설정하는 `x-vercel-forwarded-for`를 사용합니다. 근거: [Vercel Request headers](https://vercel.com/docs/headers/request-headers)
  - Vercel이 아닌 환경에서는 위조 가능한 전달 헤더를 신뢰하지 않고 하나의 `local` 버킷으로 제한합니다.

### 요청 제한 (Supabase `rate_limits` 테이블 + 원자적 RPC)

| 대상 | 기준 |
| --- | --- |
| 메모 작성 | IP당 10분에 20회 |
| 일반 삭제 요청 | IP당 10분에 30회 |
| 삭제 실패 (메모 ID + IP) | 10분에 5회 |
| 관리자 로그인 실패 | IP당 15분에 5회 |

- 제한은 bcrypt 실행 전에 확인합니다.
- 제한 저장소에 오류가 나면 해당 작업을 진행하지 않고 503을 반환합니다.
- 초과하면 429와 `Retry-After` 헤더를 반환합니다.

## 7. API

| 경로 | 메서드 | 설명 |
| --- | --- | --- |
| `/api/memos` | GET / POST | 목록 조회 / 메모 작성 |
| `/api/memos/[id]/delete`, `/api/memos/delete` | POST | 작성자 암호로 삭제 (공통 처리 함수) |
| `/api/admin/login` | POST | 관리자 로그인 |
| `/api/admin/logout` | POST | 로그아웃 |
| `/api/admin/session` | GET | 세션 확인 |
| `/api/admin/memos` | GET / DELETE·POST | 전체 조회 / 전체 삭제 |
| `/api/admin/delete-all` | POST | 전체 삭제 (공통 처리 함수) |
| `/api/admin/memos/[id]` | DELETE·POST | 개별 강제 삭제 |
| `/api/admin/delete` | POST | 개별 강제 삭제 (공통 처리 함수) |
