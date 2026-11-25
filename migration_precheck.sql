-- =====================================================================
-- MINDLET migration_precheck.sql — 읽기 전용 확인 쿼리 (데이터/권한 변경 없음)
-- migration.sql 적용 전에 SQL Editor 에서 실행해 결과를 확인/보관하세요.
-- =====================================================================

-- 1. 앱 관련 테이블 존재 여부
select t as table_name, to_regclass('public.' || t) is not null as exists
from unnest(array['memos', 'memo_credentials', 'admin_sessions', 'rate_limits']) t;

-- 2. 컬럼 구조 (memos.password_hash 존재 여부 확인)
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in ('memos', 'memo_credentials', 'admin_sessions', 'rate_limits')
order by table_name, ordinal_position;

-- 3. 제약조건 (PK/FK/CHECK, FK 의 ON DELETE 동작)
select conrelid::regclass as table_name, conname, contype,
       pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid in (select to_regclass('public.' || t)
                   from unnest(array['memos', 'memo_credentials', 'admin_sessions', 'rate_limits']) t)
order by 1, 2;

-- 4. 트리거
select event_object_table, trigger_name, action_timing, event_manipulation, action_statement
from information_schema.triggers
where event_object_schema = 'public'
  and event_object_table in ('memos', 'memo_credentials');

-- 5. RLS 활성 여부
select relname, relrowsecurity, relforcerowsecurity
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in ('memos', 'memo_credentials', 'admin_sessions', 'rate_limits');

-- 6. 기존 정책 (migration.sql 이 모두 제거 후 공개 조회 정책만 재생성)
select tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('memos', 'memo_credentials', 'admin_sessions', 'rate_limits');

-- 7. 테이블/컬럼 권한
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('memos', 'memo_credentials', 'admin_sessions', 'rate_limits')
order by table_name, grantee, privilege_type;

select grantee, table_name, column_name, privilege_type
from information_schema.column_privileges
where table_schema = 'public'
  and table_name in ('memos', 'memo_credentials')
  and grantee in ('anon', 'authenticated', 'PUBLIC')
order by table_name, grantee, column_name;

-- 8. 앱 함수, SECURITY DEFINER 여부, 실행 권한
select p.oid::regprocedure as function, p.prosecdef as security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('create_memo_with_credentials', 'consume_rate_limit',
                    'release_rate_limit', 'set_updated_at', 'mindlet_set_updated_at');

-- 9. 건수와 해시 상태 (memos.password_hash 가 있을 때만 두 번째 쿼리 실행)
select (select count(*) from public.memos) as memos,
       (select count(*) from public.memo_credentials) as credentials,
       (select count(*) from public.memos m
        where not exists (select 1 from public.memo_credentials c where c.memo_id = m.id)) as memos_without_credentials;
-- 9-1. memos.password_hash 가 있는 경우에만 실행:
-- select count(*) filter (where password_hash is null) as null_hash,
--        count(*) filter (where password_hash !~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$') as non_bcrypt
-- from public.memos;

-- 10. password_hash 컬럼에 의존하는 뷰 (있으면 migration.sql 이 중단됨)
select distinct v.relname as dependent_view
from pg_depend d
join pg_rewrite rw on rw.oid = d.objid
join pg_class v on v.oid = rw.ev_class
join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
where d.refobjid = to_regclass('public.memos') and a.attname = 'password_hash';