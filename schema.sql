-- =====================================================================
-- MINDLET schema.sql — 신규(빈) Supabase 프로젝트 전용
-- 기존 memos 테이블이 있는 DB에는 migration.sql 을 사용하세요.
-- 샘플 데이터는 넣지 않습니다. 여러 번 실행해도 안전합니다(idempotent).
-- =====================================================================

-- 0. 안전장치: 이 스크립트로 만든 구조가 아닌 기존 memos 가 있으면 중단
do $$
begin
  if to_regclass('public.memos') is not null and (
    exists (select 1 from information_schema.columns
            where table_schema = 'public' and table_name = 'memos' and column_name = 'password_hash')
    or (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'memos'
          and column_name in ('id', 'title', 'content', 'color', 'position', 'created_at', 'updated_at')) < 7
    or not exists (select 1 from pg_constraint
                   where conrelid = to_regclass('public.memos') and conname = 'memos_color_pastel')
  ) then
    raise exception '기존(구버전) memos 테이블이 있습니다. schema.sql 대신 migration.sql 을 사용하세요.';
  end if;
end;
$$;

-- 1. 공개 메모 테이블 (암호/해시 없음)
create table if not exists public.memos (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  content text not null,
  color text not null default '#fef3c7',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint memos_title_length check (char_length(title) between 1 and 80 and btrim(title) <> ''),
  constraint memos_content_length check (char_length(content) between 1 and 2000 and btrim(content) <> ''),
  constraint memos_color_pastel check (color in (
    '#fef3c7', '#dbeafe', '#dcfce7', '#fce7f3', '#f3e8ff', '#fed7aa', '#e0f2fe', '#fae8ff'
  ))
);

-- 2. 비공개: 작성자 암호 bcrypt 해시 (메모 삭제 시 함께 삭제)
create table if not exists public.memo_credentials (
  memo_id uuid primary key references public.memos(id) on delete cascade,
  password_hash text not null,
  constraint memo_credentials_bcrypt check (password_hash ~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$')
);

-- 3. 비공개: 관리자 세션 (원본 토큰이 아닌 HMAC 검증값만 저장)
create table if not exists public.admin_sessions (
  token_hmac text primary key check (token_hmac ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

-- 4. 비공개: 요청 횟수 제한 (키는 서버에서 HMAC 처리된 값, 원본 IP 저장 안 함)
create table if not exists public.rate_limits (
  key text primary key check (char_length(key) between 1 and 200),
  hits integer not null default 0,
  window_start timestamptz not null default now()
);

create index if not exists memos_created_at_idx on public.memos (created_at desc);
create index if not exists memos_position_idx on public.memos (position asc, created_at desc);
create index if not exists admin_sessions_expires_at_idx on public.admin_sessions (expires_at);
create index if not exists rate_limits_window_start_idx on public.rate_limits (window_start);

-- 5. updated_at 트리거 (다른 테이블의 공용 set_updated_at 을 덮어쓰지 않도록 전용 이름 사용)
create or replace function public.mindlet_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists memos_set_updated_at on public.memos;
create trigger memos_set_updated_at
before update on public.memos
for each row execute function public.mindlet_set_updated_at();

-- 6. 메모 + 암호 해시 원자적 저장 (단일 트랜잭션, 서버 역할 전용)
--    SECURITY INVOKER: service_role 권한으로만 실행되므로 DEFINER 불필요.
drop function if exists public.create_memo_with_credentials(text, text, text, text);
create function public.create_memo_with_credentials(
  p_title text,
  p_content text,
  p_password_hash text,
  p_color text default '#fef3c7'
)
returns public.memos
language plpgsql
security invoker
set search_path = ''
as $$
declare
  inserted_memo public.memos;
begin
  if p_title is null or btrim(p_title) = '' or char_length(p_title) > 80 then
    raise exception 'Invalid title';
  end if;
  if p_content is null or btrim(p_content) = '' or char_length(p_content) > 2000 then
    raise exception 'Invalid content';
  end if;
  if coalesce(nullif(p_color, ''), '#fef3c7') not in (
    '#fef3c7', '#dbeafe', '#dcfce7', '#fce7f3', '#f3e8ff', '#fed7aa', '#e0f2fe', '#fae8ff'
  ) then
    raise exception 'Invalid color';
  end if;
  if p_password_hash is null
     or p_password_hash !~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$' then
    raise exception 'Invalid password hash';
  end if;

  insert into public.memos (title, content, color)
  values (p_title, p_content, coalesce(nullif(p_color, ''), '#fef3c7'))
  returning * into inserted_memo;

  insert into public.memo_credentials (memo_id, password_hash)
  values (inserted_memo.id, p_password_hash);

  return inserted_memo;
end;
$$;

-- 7. 원자적 요청 제한 (고정 윈도). 허용이면 true, 초과면 false.
create or replace function public.consume_rate_limit(
  p_key text,
  p_limit integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_hits integer;
begin
  if p_key is null or char_length(p_key) not between 1 and 200
     or p_limit is null or p_limit < 1
     or p_window_seconds is null or p_window_seconds < 1 then
    raise exception 'Invalid rate limit arguments';
  end if;

  insert into public.rate_limits as r (key, hits, window_start)
  values (p_key, 1, now())
  on conflict (key) do update
    set hits = case
          when r.window_start <= now() - make_interval(secs => p_window_seconds) then 1
          else r.hits + 1
        end,
        window_start = case
          when r.window_start <= now() - make_interval(secs => p_window_seconds) then now()
          else r.window_start
        end
  returning r.hits into v_hits;

  if random() < 0.02 then
    delete from public.rate_limits where window_start < now() - interval '1 day';
  end if;

  return v_hits <= p_limit;
end;
$$;

create or replace function public.release_rate_limit(p_key text)
returns void
language sql
security invoker
set search_path = ''
as $$
  update public.rate_limits set hits = greatest(hits - 1, 0) where key = p_key;
$$;

-- 8. RLS 활성화 (모든 앱 테이블)
alter table public.memos enable row level security;
alter table public.memo_credentials enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.rate_limits enable row level security;

-- 9. 앱 테이블의 기존 정책을 모두 제거 후 필요한 공개 조회 정책만 생성
do $$
declare
  pol record;
begin
  for pol in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('memos', 'memo_credentials', 'admin_sessions', 'rate_limits')
  loop
    execute format('drop policy %I on public.%I', pol.policyname, pol.tablename);
  end loop;
end;
$$;

create policy "Public memos are readable"
on public.memos
for select
to anon, authenticated
using (true);
-- memo_credentials / admin_sessions / rate_limits: 일반 사용자 정책 없음 (의도적)

-- 10. 테이블 권한 (앱 테이블에 한정)
revoke all on table public.memos, public.memo_credentials, public.admin_sessions, public.rate_limits
  from public, anon, authenticated;

grant select (id, title, content, color, position, created_at, updated_at)
  on table public.memos to anon, authenticated;

grant select, insert, update, delete
  on table public.memos, public.memo_credentials, public.admin_sessions, public.rate_limits
  to service_role;

-- 11. 함수 실행 권한: 서버 역할(service_role)만
revoke all on function public.create_memo_with_credentials(text, text, text, text) from public, anon, authenticated;
revoke all on function public.consume_rate_limit(text, integer, integer) from public, anon, authenticated;
revoke all on function public.release_rate_limit(text) from public, anon, authenticated;
revoke all on function public.mindlet_set_updated_at() from public, anon, authenticated;

grant execute on function public.create_memo_with_credentials(text, text, text, text) to service_role;
grant execute on function public.consume_rate_limit(text, integer, integer) to service_role;
grant execute on function public.release_rate_limit(text) to service_role;

-- ---------------------------------------------------------------------
-- 12. 최종 검증
-- ---------------------------------------------------------------------
do $$
declare
  t text;
  r text;
  priv text;
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'memos' and column_name = 'password_hash') then
    raise exception '검증 실패: memos.password_hash 가 남아 있습니다.';
  end if;

  foreach t in array array['memos', 'memo_credentials', 'admin_sessions', 'rate_limits'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception '검증 실패: %.RLS 비활성', t;
    end if;
  end loop;

  foreach r in array array['anon', 'authenticated'] loop
    foreach priv in array array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
      if has_table_privilege(r, 'public.memos', priv) then
        raise exception '검증 실패: % 가 memos % 권한을 가짐', r, priv;
      end if;
    end loop;
    if not has_column_privilege(r, 'public.memos', 'title', 'SELECT') then
      raise exception '검증 실패: % 가 memos 공개 컬럼을 조회할 수 없음', r;
    end if;
    foreach t in array array['memo_credentials', 'admin_sessions', 'rate_limits'] loop
      if has_any_column_privilege(r, 'public.' || t, 'SELECT')
         or has_table_privilege(r, 'public.' || t, 'INSERT')
         or has_table_privilege(r, 'public.' || t, 'UPDATE')
         or has_table_privilege(r, 'public.' || t, 'DELETE') then
        raise exception '검증 실패: % 가 % 에 접근 가능', r, t;
      end if;
    end loop;
    if has_function_privilege(r, 'public.create_memo_with_credentials(text, text, text, text)', 'EXECUTE')
       or has_function_privilege(r, 'public.consume_rate_limit(text, integer, integer)', 'EXECUTE')
       or has_function_privilege(r, 'public.release_rate_limit(text)', 'EXECUTE') then
      raise exception '검증 실패: % 가 서버 전용 RPC 를 실행 가능', r;
    end if;
  end loop;

  if (select count(*) from pg_policies where schemaname = 'public'
      and tablename in ('memo_credentials', 'admin_sessions', 'rate_limits')) > 0 then
    raise exception '검증 실패: 비공개 테이블에 정책이 존재';
  end if;

  raise notice '스키마 검증 통과. 메모 %건, 암호 해시 %건',
    (select count(*) from public.memos), (select count(*) from public.memo_credentials);
end;
$$;

-- PostgREST 스키마 캐시 갱신
notify pgrst, 'reload schema';
