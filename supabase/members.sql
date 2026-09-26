-- ═══════════════════════════════════════════════════════════════════
--  SeeON 자체 회원가입 — 동의 기록 · 이메일 중복 확인 · 회원 탈퇴
--  schema.sql, admin.sql 다음에 실행 (여러 번 실행해도 안전)
-- ═══════════════════════════════════════════════════════════════════

-- ── 동의 기록 (언제 어떤 버전에 동의/철회했는지 증빙) ────────────────────
create table if not exists public.seeon_consents (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('terms','privacy','age14','guardian','marketing_email')),
  agreed     boolean not null,
  version    text not null,
  created_at timestamptz not null default now()
);
create index if not exists seeon_consents_user_idx on public.seeon_consents(user_id, kind, created_at desc);
alter table public.seeon_consents enable row level security;
drop policy if exists "seeon_consents_read_own" on public.seeon_consents;
create policy "seeon_consents_read_own" on public.seeon_consents for select to authenticated using (user_id = auth.uid());
revoke all on public.seeon_consents from anon, authenticated;
grant select on public.seeon_consents to authenticated;   -- 쓰기는 아래 함수로만

-- 내 동의 상태
create or replace function public.seeon_consent_status(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'version', (select version from public.seeon_consents where user_id = p_user and kind = 'terms' order by created_at desc limit 1),
    'agreed_at', (select min(created_at) from public.seeon_consents where user_id = p_user and kind = 'terms'),
    'marketing', coalesce((select agreed from public.seeon_consents where user_id = p_user and kind = 'marketing_email' order by created_at desc, id desc limit 1), false),
    'marketing_at', (select created_at from public.seeon_consents where user_id = p_user and kind = 'marketing_email' order by created_at desc, id desc limit 1),
    -- 카메라 선택 동의(eye.sql)도 함께: members.sql 을 다시 실행해도 눈 측정·시력 기록 동의가 사라지지 않게
    'eye', coalesce((select agreed from public.seeon_consents where user_id = p_user and kind = 'eye_metrics' order by created_at desc, id desc limit 1), false),
    'eye_at', (select created_at from public.seeon_consents where user_id = p_user and kind = 'eye_metrics' order by created_at desc, id desc limit 1),
    'vision', coalesce((select agreed from public.seeon_consents where user_id = p_user and kind = 'vision_results' order by created_at desc, id desc limit 1), false),
    'vision_at', (select created_at from public.seeon_consents where user_id = p_user and kind = 'vision_results' order by created_at desc, id desc limit 1))
$$;

-- 가입 때 받은 동의(가입 요청에 함께 저장됨)를 기록 — 로그인할 때마다 불러도 한 번만 기록
create or replace function public.seeon_consent_sync() returns jsonb
language plpgsql volatile security definer set search_path = public, auth as $$
declare uid uuid := auth.uid(); c jsonb; created timestamptz; v text;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  select raw_user_meta_data->'consent', u.created_at into c, created from auth.users u where u.id = uid;
  if not exists (select 1 from public.seeon_consents where user_id = uid and kind = 'terms') then
    if c is null or jsonb_typeof(c) <> 'object'
       or coalesce(c->>'terms', '') <> 'true' or coalesce(c->>'privacy', '') <> 'true'
       or coalesce(c->>'age14', '') <> 'true' or coalesce(c->>'guardian', '') <> 'true' then
      return jsonb_build_object('missing', true);
    end if;
    v := left(coalesce(c->>'v', 'unknown'), 20);
    insert into public.seeon_consents (user_id, kind, agreed, version, created_at) values
      (uid, 'terms', true, v, created), (uid, 'privacy', true, v, created),
      (uid, 'age14', true, v, created), (uid, 'guardian', true, v, created),
      (uid, 'marketing_email', coalesce(c->>'marketing', '') = 'true', v, created);
  end if;
  return public.seeon_consent_status(uid);
end $$;

-- 필수 동의를 나중에 받을 때 (예: 소셜 로그인 또는 약관 개정 후 재동의)
create or replace function public.seeon_consent_accept(p_version text, p_marketing boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); v text := left(coalesce(p_version, 'unknown'), 20);
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  insert into public.seeon_consents (user_id, kind, agreed, version) values
    (uid, 'terms', true, v), (uid, 'privacy', true, v), (uid, 'age14', true, v), (uid, 'guardian', true, v),
    (uid, 'marketing_email', coalesce(p_marketing, false), v);
  return public.seeon_consent_status(uid);
end $$;

-- 광고성 정보(이메일) 수신 동의 / 철회
create or replace function public.seeon_set_marketing(p_on boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); v text;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  select version into v from public.seeon_consents where user_id = uid and kind = 'terms' order by created_at desc limit 1;
  insert into public.seeon_consents (user_id, kind, agreed, version) values (uid, 'marketing_email', coalesce(p_on, false), coalesce(v, 'unknown'));
  return public.seeon_consent_status(uid);
end $$;

-- ── 이메일 중복 확인 (가입 전, 로그인 없이 호출) ──────────────────────────
create or replace function public.seeon_email_available(p_email text) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select case
    when p_email is null or length(p_email) > 254 or lower(trim(p_email)) !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then false
    else not exists (select 1 from auth.users where lower(email) = lower(trim(p_email)))
  end
$$;

-- ── 회원 탈퇴: 계정과 모든 기록(조종사·게임 기록·동의 기록)을 즉시 삭제 ─────
create or replace function public.seeon_delete_me() returns jsonb
language plpgsql volatile security definer set search_path = public, auth as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  if exists (select 1 from public.seeon_admins where user_id = uid) then
    raise exception '관리자 계정은 탈퇴 전에 다른 관리자가 관리자 권한을 해제해야 해요.';
  end if;
  delete from public.seeon_profiles where user_id = uid;   -- 기록은 함께 삭제
  delete from auth.users where id = uid;                    -- 동의 기록 등은 함께 삭제
  return jsonb_build_object('ok', true);
end $$;

-- ── 관리자: 사용자 목록·상세에 인증·동의 정보 추가 ─────────────────────
create or replace function public.seeon_admin_consents(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public.seeon_admin_guard();
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'agreed', agreed, 'version', version, 'at', created_at) order by created_at desc, id desc), '[]')
    into r from public.seeon_consents where user_id = p_user;
  return jsonb_build_object('status', public.seeon_consent_status(p_user), 'log', r,
    'confirmed_at', (select email_confirmed_at from auth.users where id = p_user));
end $$;

-- 광고성 정보 수신 동의자 목록 (메일 발송·2년마다 재확인용)
create or replace function public.seeon_admin_marketing() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  perform public.seeon_admin_guard();
  select coalesce(jsonb_agg(t order by t.since), '[]') into r from (
    select u.email, public.seeon_uname(u) as name, (s->>'marketing_at')::timestamptz as since,
           ((s->>'marketing_at')::timestamptz < now() - interval '23 months') as reconfirm_due
    from auth.users u cross join lateral (select public.seeon_consent_status(u.id) as s) x
    where coalesce((x.s->>'marketing')::boolean, false) and u.email is not null) t;
  return r;
end $$;


-- ═══ 관리자 사용자 목록 (인증·광고 수신 동의 포함으로 갱신) ═════════════════════════════════════════════════
create or replace function public.seeon_admin_users(p_q text default '', p_sort text default 'recent', p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare q text := lower(trim(coalesce(p_q, ''))); r jsonb;
begin
  perform public.seeon_admin_guard();
  with base as (
    select u.id, u.email, public.seeon_uname(u) as name,
      coalesce(nullif(u.raw_app_meta_data->>'provider', ''), 'email') as provider,
      u.created_at, u.last_sign_in_at,
      (select count(*) from public.seeon_profiles p where p.user_id = u.id) as n_profiles,
      (select count(*) from public.seeon_records x where x.user_id = u.id) as n_records,
      (select coalesce(round(sum(x.dur) / 60.0), 0) from public.seeon_records x where x.user_id = u.id) as minutes,
      (select max(x.played_at) from public.seeon_records x where x.user_id = u.id) as last_play,
      (select count(distinct public.seeon_kday(x.played_at)) from public.seeon_records x
         where x.user_id = u.id and x.played_at > now() - interval '30 days') as days30,
      (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nickname', p.nickname, 'avatar', p.avatar, 'level', p.level) order by p.created_at), '[]')
         from public.seeon_profiles p where p.user_id = u.id) as kids,
      exists (select 1 from public.seeon_blocked b where b.user_id = u.id) as blocked,
      exists (select 1 from public.seeon_admins a where a.user_id = u.id) as admin,
      (u.email_confirmed_at is not null) as confirmed,
      coalesce((select c.agreed from public.seeon_consents c where c.user_id = u.id and c.kind = 'marketing_email' order by c.created_at desc, c.id desc limit 1), false) as marketing
    from auth.users u
  ), filtered as (
    select * from base b
    where q = '' or lower(coalesce(b.email, '')) like '%' || q || '%' or lower(b.name) like '%' || q || '%'
       or exists (select 1 from jsonb_array_elements(b.kids) k where lower(k->>'nickname') like '%' || q || '%')
       or b.id::text = q
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from (
      select * from filtered
      order by
        case when p_sort = 'plays' then n_records end desc nulls last,
        case when p_sort = 'minutes' then minutes end desc nulls last,
        case when p_sort = 'last_play' then last_play end desc nulls last,
        case when p_sort = 'name' then name end asc,
        created_at desc
      limit greatest(1, least(coalesce(p_limit, 50), 500)) offset greatest(0, coalesce(p_offset, 0))) t)
  ) into r;
  return r;
end $$;


-- ── 실행 권한 ───────────────────────────────────────────────────────
revoke all on function public.seeon_consent_status(uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['seeon_consent_sync()', 'seeon_consent_accept(text, boolean)', 'seeon_set_marketing(boolean)',
                           'seeon_delete_me()', 'seeon_admin_consents(uuid)', 'seeon_admin_marketing()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke all on function public.seeon_email_available(text) from public;
grant execute on function public.seeon_email_available(text) to anon, authenticated;

-- ── 조종사(아이 프로필) 삭제 — 그 조종사의 게임 기록도 함께 지워져요 (기록은 on delete cascade) ──
create or replace function public.seeon_delete_profile(p_profile bigint) returns int
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  delete from public.seeon_profiles where id = p_profile and user_id = uid;
  get diagnostics n = row_count;
  if n = 0 then raise exception '조종사를 찾을 수 없어요.' using errcode = 'P0002'; end if;
  return (select count(*) from public.seeon_profiles where user_id = uid)::int;
end $$;
revoke all on function public.seeon_delete_profile(bigint) from public, anon;
grant execute on function public.seeon_delete_profile(bigint) to authenticated;
