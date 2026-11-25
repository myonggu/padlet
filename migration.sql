-- =====================================================================
-- MINDLET migration.sql — 기존 memos 데이터가 있는 DB 변경용 (데이터 보존)
--
-- 적용 전제조건
--   1) migration_precheck.sql 을 먼저 실행해 실제 구조/정책/권한/건수를 확인했을 것
--   2) Supabase 대시보드에서 백업(또는 PITR)을 확보했을 것
--   3) public.memos.id 가 uuid 이고 title/content/created_at 컬럼이 있을 것
--   4) memos.password_hash 컬럼(구버전)을 참조하는 뷰가 없을 것 (있으면 중단됨)
--   5) 앱 배포를 잠시 멈추거나 쓰기가 없는 시간에 실행할 것
--
-- 전체가 하나의 트랜잭션입니다. 검증에 실패하면 RAISE EXCEPTION 으로 전부 롤백됩니다.
-- 보존: 메모 id, 제목, 내용, 색상, created_at, updated_at, 기존 bcrypt 해시
-- 관련 없는 테이블이나 public 스키마 전체 권한은 변경하지 않습니다.
-- 여러 번 실행해도 안전합니다(idempotent).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. 기존 구조 확인
-- ---------------------------------------------------------------------
do $$
declare
  v_type text;
  v_col text;
begin
  if to_regclass('public.memos') is null then
    raise exception 'public.memos 가 없습니다. 신규 DB에는 schema.sql 을 사용하세요.';
  end if;

  select data_type into v_type from information_schema.columns
  where table_schema = 'public' and table_name = 'memos' and column_name = 'id';
  if v_type is distinct from 'uuid' then
    raise exception 'memos.id 가 uuid 가 아닙니다(현재: %). 수동 변환이 필요합니다.', coalesce(v_type, '없음');
  end if;

  foreach v_col in array array['title', 'content', 'created_at'] loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'memos' and column_name = v_col
    ) then
      raise exception 'memos.% 컬럼이 없습니다. 수동 확인이 필요합니다.', v_col;
    end if;
  end loop;

  raise notice '기존 메모 수: %', (select count(*) from public.memos);
end;
$$;

-- 데이터 수정 중 updated_at 이 바뀌지 않도록 기존 트리거를 먼저 제거 (끝에서 재생성)
drop trigger if exists memos_set_updated_at on public.memos;

-- ---------------------------------------------------------------------
-- 2. 누락 컬럼 추가 (기존 값은 그대로 유지)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'memos' and column_name = 'color') then
    alter table public.memos add column color text;
  end if;
  update public.memos set color = '#fef3c7' where color is null or color = '';
  alter table public.memos alter column color set default '#fef3c7';
  alter table public.memos alter column color set not null;

  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'memos' and column_name = 'position') then
    alter table public.memos add column position integer;
  end if;
  update public.memos set position = 0 where position is null;
  alter table public.memos alter column position set default 0;
  alter table public.memos alter column position set not null;

  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'memos' and column_name = 'updated_at') then
    alter table public.memos add column updated_at timestamptz;
  end if;
  update public.memos set updated_at = created_at where updated_at is null;
  alter table public.memos alter column updated_at set default now();
  alter table public.memos alter column updated_at set not null;

  update public.memos set created_at = now() where created_at is null;
  alter table public.memos alter column created_at set default now();
  alter table public.memos alter column created_at set not null;

  alter table public.memos alter column id set default gen_random_uuid();
end;
$$;

-- ---------------------------------------------------------------------
-- 3. 비공개 테이블 생성/점검
-- ---------------------------------------------------------------------
create table if not exists public.memo_credentials (
  memo_id uuid primary key references public.memos(id) on delete cascade,
  password_hash text not null
);

do $$
declare
  v_con record;
  v_count bigint;
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'memo_credentials' and column_name = 'password_hash') then
    raise exception 'memo_credentials.password_hash 컬럼이 없습니다. 수동 확인이 필요합니다.';
  end if;

  -- 중복 검증
  select count(*) into v_count from (
    select memo_id from public.memo_credentials group by memo_id having count(*) > 1
  ) d;
  if v_count > 0 then
    raise exception 'memo_credentials 에 중복 memo_id 가 % 건 있습니다. 수동 정리가 필요합니다.', v_count;
  end if;

  -- 고아 행 제거 (참조할 메모가 없는 해시)
  delete from public.memo_credentials c
  where not exists (select 1 from public.memos m where m.id = c.memo_id);
  get diagnostics v_count = row_count;
  if v_count > 0 then
    raise notice '메모가 없는 고아 암호 해시 % 건을 삭제했습니다.', v_count;
  end if;

  -- 기본키 보장
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.memo_credentials'::regclass and contype = 'p') then
    alter table public.memo_credentials add primary key (memo_id);
  end if;

  -- memos 를 참조하는 FK 를 ON DELETE CASCADE 로 통일
  for v_con in
    select conname from pg_constraint
    where conrelid = 'public.memo_credentials'::regclass
      and contype = 'f'
      and confrelid = 'public.memos'::regclass
      and confdeltype <> 'c'
  loop
    execute format('alter table public.memo_credentials drop constraint %I', v_con.conname);
  end loop;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.memo_credentials'::regclass
                   and contype = 'f' and confrelid = 'public.memos'::regclass) then
    alter table public.memo_credentials
      add constraint memo_credentials_memo_id_fkey
      foreign key (memo_id) references public.memos(id) on delete cascade;
  end if;
end;
$$;

create table if not exists public.admin_sessions (
  token_hmac text primary key check (token_hmac ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists public.rate_limits (
  key text primary key check (char_length(key) between 1 and 200),
  hits integer not null default 0,
  window_start timestamptz not null default now()
);

create index if not exists memos_created_at_idx on public.memos (created_at desc);
create index if not exists memos_position_idx on public.memos (position asc, created_at desc);
create index if not exists admin_sessions_expires_at_idx on public.admin_sessions (expires_at);
create index if not exists rate_limits_window_start_idx on public.rate_limits (window_start);

-- ---------------------------------------------------------------------
-- 4. 기존 정책 전부 제거 (password_hash 를 참조하는 정책이 있어도 컬럼 제거가 가능하도록 먼저 수행)
-- ---------------------------------------------------------------------
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
    raise notice '정책 제거: %.%', pol.tablename, pol.policyname;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. 구버전 memos.password_hash → memo_credentials 이전 및 검증 후 제거
-- ---------------------------------------------------------------------
do $$
declare
  v_bad bigint;
  v_moved bigint;
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'memos' and column_name = 'password_hash') then
    raise notice 'memos.password_hash 컬럼 없음 — 해시 이전 단계 생략';
    return;
  end if;

  -- 형식 검증: 이전 대상 중 bcrypt 가 아닌 값이 있으면 중단
  execute $q$
    select count(*) from public.memos m
    where m.password_hash is not null
      and m.password_hash !~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'
      and not exists (select 1 from public.memo_credentials c where c.memo_id = m.id)
  $q$ into v_bad;
  if v_bad > 0 then
    raise exception 'bcrypt 형식이 아닌 memos.password_hash 가 % 건 있습니다. 평문 암호일 수 있으니 수동 확인하세요.', v_bad;
  end if;

  execute $q$
    insert into public.memo_credentials (memo_id, password_hash)
    select m.id, m.password_hash from public.memos m
    where m.password_hash is not null
    on conflict (memo_id) do nothing
  $q$;
  get diagnostics v_moved = row_count;
  raise notice 'memo_credentials 로 이전한 해시: % 건', v_moved;

  -- 충돌 검증: 이미 있던 해시와 컬럼 값이 다르면 중단
  execute $q$
    select count(*) from public.memos m
    join public.memo_credentials c on c.memo_id = m.id
    where m.password_hash is not null and c.password_hash <> m.password_hash
  $q$ into v_bad;
  if v_bad > 0 then
    raise exception 'memos.password_hash 와 memo_credentials 값이 다른 메모가 % 건 있습니다. 수동 확인하세요.', v_bad;
  end if;

  -- 누락 검증
  execute $q$
    select count(*) from public.memos m
    where m.password_hash is not null
      and not exists (select 1 from public.memo_credentials c where c.memo_id = m.id)
  $q$ into v_bad;
  if v_bad > 0 then
    raise exception '이전되지 않은 해시가 % 건 있습니다.', v_bad;
  end if;

  -- 공개 테이블에서 해시 제거 (CASCADE 없이: 의존 뷰가 있으면 중단되어 안전)
  alter table public.memos drop column password_hash;
  raise notice 'memos.password_hash 컬럼을 제거했습니다.';
end;
$$;

do $$
declare
  v_missing bigint;
begin
  select count(*) into v_missing from public.memos m
  where not exists (select 1 from public.memo_credentials c where c.memo_id = m.id);
  if v_missing > 0 then
    raise notice '작성자 암호가 없는 메모 % 건: 관리자만 삭제할 수 있습니다.', v_missing;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. 함수 교체 (SECURITY DEFINER → INVOKER, 서버 역할 전용)
-- ---------------------------------------------------------------------
do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure as sig from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_memo_with_credentials'
  loop
    execute format('drop function %s', fn.sig);
  end loop;
end;
$$;

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

-- 공용 set_updated_at 은 다른 테이블이 쓸 수 있으므로 건드리지 않고 전용 함수 사용
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

create trigger memos_set_updated_at
before update on public.memos
for each row execute function public.mindlet_set_updated_at();

-- ---------------------------------------------------------------------
-- 7. RLS, 정책, 권한 재적용 (앱 테이블과 앱 함수에만)
-- ---------------------------------------------------------------------
alter table public.memos enable row level security;
alter table public.memo_credentials enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.rate_limits enable row level security;

create policy "Public memos are readable"
on public.memos
for select
to anon, authenticated
using (true);

revoke all on table public.memos, public.memo_credentials, public.admin_sessions, public.rate_limits
  from public, anon, authenticated;

grant select (id, title, content, color, position, created_at, updated_at)
  on table public.memos to anon, authenticated;

grant select, insert, update, delete
  on table public.memos, public.memo_credentials, public.admin_sessions, public.rate_limits
  to service_role;

revoke all on function public.create_memo_with_credentials(text, text, text, text) from public, anon, authenticated;
revoke all on function public.consume_rate_limit(text, integer, integer) from public, anon, authenticated;
revoke all on function public.release_rate_limit(text) from public, anon, authenticated;
revoke all on function public.mindlet_set_updated_at() from public, anon, authenticated;

grant execute on function public.create_memo_with_credentials(text, text, text, text) to service_role;
grant execute on function public.consume_rate_limit(text, integer, integer) to service_role;
grant execute on function public.release_rate_limit(text) to service_role;

-- ---------------------------------------------------------------------
-- 8. 최종 검증 (실패 시 전체 롤백)
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

  raise notice '마이그레이션 검증 통과. 메모 %건, 암호 해시 %건',
    (select count(*) from public.memos), (select count(*) from public.memo_credentials);
end;
$$;

commit;

notify pgrst, 'reload schema';
