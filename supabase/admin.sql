-- ═══════════════════════════════════════════════════════════════════
--  SeeON 관리자 기능 — schema.sql 다음에 한 번 실행
--  Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣고 Run
--  (여러 번 실행해도 안전합니다)
--
--  ★ 실행 후 맨 아래 "첫 관리자 지정" 부분의 이메일을 바꿔서 한 번 더 실행하세요.
-- ═══════════════════════════════════════════════════════════════════

-- ── 관리자 / 이용 제한 목록 (직접 접근 불가, 아래 함수로만 다룸) ─────────
create table if not exists public.seeon_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.seeon_blocked (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  reason     text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.seeon_admins  enable row level security;
alter table public.seeon_blocked enable row level security;
revoke all on public.seeon_admins, public.seeon_blocked from anon, authenticated;

create or replace function public.seeon_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.seeon_admins where user_id = auth.uid())
$$;
create or replace function public.seeon_is_blocked() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.seeon_blocked where user_id = auth.uid())
$$;

-- 게임이 로그인 직후 확인하는 내 상태
create or replace function public.seeon_me_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('blocked', public.seeon_is_blocked(), 'admin', public.seeon_is_admin())
$$;

-- ── 이용 제한된 계정은 자기 기록도 읽고 쓸 수 없음 ──────────────────────
drop policy if exists "seeon_profiles_own" on public.seeon_profiles;
create policy "seeon_profiles_own" on public.seeon_profiles
  for all to authenticated
  using (user_id = auth.uid() and not public.seeon_is_blocked())
  with check (user_id = auth.uid() and not public.seeon_is_blocked());

drop policy if exists "seeon_records_own" on public.seeon_records;
create policy "seeon_records_own" on public.seeon_records
  for all to authenticated
  using (user_id = auth.uid() and not public.seeon_is_blocked())
  with check (
    user_id = auth.uid() and not public.seeon_is_blocked()
    and exists (select 1 from public.seeon_profiles p where p.id = profile_id and p.user_id = auth.uid())
  );

-- ── 공통 도우미 ─────────────────────────────────────────────────────
create or replace function public.seeon_admin_guard() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.seeon_is_admin() then
    raise exception '관리자만 사용할 수 있어요.' using errcode = '42501';
  end if;
end $$;

-- 한국 시간 기준 날짜
create or replace function public.seeon_kday(t timestamptz) returns date
language sql immutable as $$ select (t at time zone 'Asia/Seoul')::date $$;

-- 게임 키 정리 ("meteor.2" → "meteor")
create or replace function public.seeon_gkey(k text) returns text
language sql immutable as $$ select split_part(coalesce(k, 'unknown'), '.', 1) $$;

-- 계정 표시 이름
create or replace function public.seeon_uname(u auth.users) returns text
language sql stable as $$
  select coalesce(
    nullif(u.raw_user_meta_data->>'name', ''), nullif(u.raw_user_meta_data->>'full_name', ''),
    nullif(u.raw_user_meta_data->>'nickname', ''), nullif(u.raw_user_meta_data->>'preferred_username', ''),
    nullif(split_part(coalesce(u.email, ''), '@', 1), ''), '(이름 없음)')
$$;

-- ═══ 1. 전체 분석 ═══════════════════════════════════════════════════
create or replace function public.seeon_admin_overview(p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare
  d int := greatest(7, least(coalesce(p_days, 30), 365));
  since date := public.seeon_kday(now()) - (d - 1);
  prev_since date := since - d;
  r jsonb;
begin
  perform public.seeon_admin_guard();
  with recs as (
    select r.*, public.seeon_kday(r.played_at) as day, public.seeon_gkey(r.game_key) as g
    from public.seeon_records r
  ),
  days as (select generate_series(since, public.seeon_kday(now()), interval '1 day')::date as day),
  series as (
    select dd.day,
      (select count(*) from auth.users u where public.seeon_kday(u.created_at) = dd.day) as new_accounts,
      (select count(distinct x.user_id) from recs x where x.day = dd.day) as active,
      (select count(*) from recs x where x.day = dd.day) as plays,
      (select coalesce(round(sum(x.dur) / 60.0), 0) from recs x where x.day = dd.day) as minutes
    from days dd
  ),
  per_user as (
    select user_id, count(distinct day) as active_days, min(played_at) as first_play, max(played_at) as last_play
    from recs group by user_id
  )
  select jsonb_build_object(
    'days', d,
    'since', since,
    'totals', jsonb_build_object(
      'accounts', (select count(*) from auth.users),
      'players', (select count(distinct user_id) from public.seeon_profiles),
      'profiles', (select count(*) from public.seeon_profiles),
      'records', (select count(*) from recs),
      'minutes', (select coalesce(round(sum(dur) / 60.0), 0) from recs),
      'blocked', (select count(*) from public.seeon_blocked),
      'admins', (select count(*) from public.seeon_admins)
    ),
    'period', jsonb_build_object(
      'active', (select count(distinct user_id) from recs where day >= since),
      'active_prev', (select count(distinct user_id) from recs where day >= prev_since and day < since),
      'plays', (select count(*) from recs where day >= since),
      'plays_prev', (select count(*) from recs where day >= prev_since and day < since),
      'minutes', (select coalesce(round(sum(dur) / 60.0), 0) from recs where day >= since),
      'minutes_prev', (select coalesce(round(sum(dur) / 60.0), 0) from recs where day >= prev_since and day < since),
      'new_accounts', (select count(*) from auth.users where public.seeon_kday(created_at) >= since),
      'new_accounts_prev', (select count(*) from auth.users where public.seeon_kday(created_at) >= prev_since and public.seeon_kday(created_at) < since),
      'dau', (select count(distinct user_id) from recs where day = public.seeon_kday(now())),
      'wau', (select count(distinct user_id) from recs where day > public.seeon_kday(now()) - 7),
      'mau', (select count(distinct user_id) from recs where day > public.seeon_kday(now()) - 30)
    ),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'new', new_accounts, 'active', active, 'plays', plays, 'minutes', minutes) order by day), '[]') from series),
    'providers', (select coalesce(jsonb_object_agg(p, n), '{}') from (
        select coalesce(nullif(raw_app_meta_data->>'provider', ''), 'email') as p, count(*) as n from auth.users group by 1) t),
    'games', (select coalesce(jsonb_agg(t order by t.plays desc), '[]') from (
        select g as key, count(*) as plays, count(distinct user_id) as players,
               round(avg(stars)::numeric, 2) as avg_stars, round(avg(dur)::numeric) as avg_dur,
               round(100.0 * avg(case when stars is null then null when stars >= 3 then 1 else 0 end)::numeric) as three_star_pct,
               max(stage) as max_stage
        from recs where day >= since group by g) t),
    'stages', (select coalesce(jsonb_agg(t order by t.key, t.stage), '[]') from (
        select g as key, stage, count(*) as plays, count(distinct user_id) as players, round(avg(stars)::numeric, 2) as avg_stars
        from recs where day >= since and stage is not null group by g, stage) t),
    'heat', (select coalesce(jsonb_agg(jsonb_build_array(wd, hr, n)), '[]') from (
        select extract(dow from played_at at time zone 'Asia/Seoul')::int as wd,
               extract(hour from played_at at time zone 'Asia/Seoul')::int as hr, count(*) as n
        from recs where day >= since group by 1, 2) t),
    'engagement', jsonb_build_object(
      'players', (select count(*) from per_user),
      'returning', (select count(*) from per_user where active_days >= 2),
      'avg_active_days', (select round(avg(active_days)::numeric, 1) from per_user),
      'buckets', jsonb_build_array(
        (select count(*) from per_user where active_days = 1),
        (select count(*) from per_user where active_days between 2 and 3),
        (select count(*) from per_user where active_days between 4 and 7),
        (select count(*) from per_user where active_days between 8 and 14),
        (select count(*) from per_user where active_days >= 15)),
      'd7_base', (select count(*) from per_user where first_play < now() - interval '7 days'),
      'd7_kept', (select count(*) from per_user pu where first_play < now() - interval '7 days'
                    and exists (select 1 from recs x where x.user_id = pu.user_id and x.played_at >= pu.first_play + interval '7 days')),
      'session_minutes', (select coalesce(round(avg(m)::numeric, 1), 0) from (
          select user_id, day, sum(dur) / 60.0 as m from recs where day >= since group by user_id, day) s)
    ),
    'levels', (select coalesce(jsonb_agg(jsonb_build_array(level, n) order by level), '[]') from (
        select level, count(*) as n from public.seeon_profiles group by level) t)
  ) into r;
  return r;
end $$;

-- ═══ 2. 게임별 성과 추이 (주 단위, 대표 지표 중앙값) ═══════════════════
create or replace function public.seeon_admin_game(p_key text, p_metric text, p_weeks int default 12) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w int := greatest(4, least(coalesce(p_weeks, 12), 52)); r jsonb;
begin
  perform public.seeon_admin_guard();
  with recs as (
    select r.*, date_trunc('week', r.played_at at time zone 'Asia/Seoul')::date as wk
    from public.seeon_records r
    where public.seeon_gkey(r.game_key) = p_key and r.played_at >= now() - make_interval(weeks => w)
  )
  select jsonb_build_object(
    'weeks', (select coalesce(jsonb_agg(t order by t.wk), '[]') from (
        select wk, count(*) as plays, count(distinct user_id) as players, round(avg(stars)::numeric, 2) as avg_stars,
          round(avg(dur)::numeric) as avg_dur,
          case when p_metric is null or p_metric = '' then null else
            percentile_cont(0.5) within group (order by (m->>p_metric)::numeric)
              filter (where jsonb_typeof(m->p_metric) = 'number') end as median
        from recs group by wk) t),
    'stages', (select coalesce(jsonb_agg(t order by t.stage), '[]') from (
        select stage, count(*) as plays, count(distinct user_id) as players, round(avg(stars)::numeric, 2) as avg_stars,
          case when p_metric is null or p_metric = '' then null else
            percentile_cont(0.5) within group (order by (m->>p_metric)::numeric)
              filter (where jsonb_typeof(m->p_metric) = 'number') end as median
        from recs where stage is not null group by stage) t)
  ) into r;
  return r;
end $$;

-- ═══ 3. 사용자 목록 ═════════════════════════════════════════════════
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
      exists (select 1 from public.seeon_admins a where a.user_id = u.id) as admin
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

-- ═══ 4. 사용자 상세 ═════════════════════════════════════════════════
create or replace function public.seeon_admin_user(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  perform public.seeon_admin_guard();
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'name', public.seeon_uname(u),
        'provider', coalesce(nullif(u.raw_app_meta_data->>'provider', ''), 'email'),
        'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
        'blocked', exists (select 1 from public.seeon_blocked b where b.user_id = u.id),
        'block_reason', (select b.reason from public.seeon_blocked b where b.user_id = u.id),
        'admin', exists (select 1 from public.seeon_admins a where a.user_id = u.id))
      from auth.users u where u.id = p_user),
    'profiles', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'nickname', p.nickname, 'avatar', p.avatar, 'level', p.level, 'xp', p.xp,
        'created_at', p.created_at, 'updated_at', p.updated_at,
        'stars', (select coalesce(sum(public.seeon_num(v)), 0) from jsonb_each(p.state) e(k, v) where k like 'seeon.stars.%'),
        'records', (select count(*) from public.seeon_records x where x.profile_id = p.id),
        'minutes', (select coalesce(round(sum(x.dur) / 60.0), 0) from public.seeon_records x where x.profile_id = p.id),
        'last_play', (select max(x.played_at) from public.seeon_records x where x.profile_id = p.id),
        'breaks', coalesce(jsonb_array_length(case when jsonb_typeof(p.state->'seeon.breaks') = 'array' then p.state->'seeon.breaks' end), 0),
        'story_cleared', (select count(*) from jsonb_each(case when jsonb_typeof(p.state->'seeon.story'->'st') = 'object' then p.state->'seeon.story'->'st' else '{}'::jsonb end) e(k, v)
                          where public.seeon_num(v->'s') >= 1),
        'story_stars', (select coalesce(sum(least(3, public.seeon_num(v->'s'))), 0) from jsonb_each(case when jsonb_typeof(p.state->'seeon.story'->'st') = 'object' then p.state->'seeon.story'->'st' else '{}'::jsonb end) e(k, v))
      ) order by p.created_at), '[]') from public.seeon_profiles p where p.user_id = p_user),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d, 'plays', n, 'minutes', mn) order by d), '[]') from (
        select public.seeon_kday(played_at) as d, count(*) as n, round(sum(dur) / 60.0) as mn
        from public.seeon_records where user_id = p_user and played_at > now() - interval '30 days' group by 1) t),
    'games', (select coalesce(jsonb_agg(t order by t.plays desc), '[]') from (
        select public.seeon_gkey(game_key) as key, count(*) as plays, round(avg(stars)::numeric, 2) as avg_stars, max(stage) as max_stage
        from public.seeon_records where user_id = p_user group by 1) t),
    'records', (select coalesce(jsonb_agg(t order by t.played_at desc), '[]') from (
        select x.profile_id, public.seeon_gkey(x.game_key) as key, x.stage, x.stars, x.dur, x.m, x.played_at
        from public.seeon_records x where x.user_id = p_user order by x.played_at desc limit 200) t)
  ) into r;
  if r->'account' is null or jsonb_typeof(r->'account') = 'null' then
    raise exception '사용자를 찾을 수 없어요.' using errcode = 'P0002';
  end if;
  return r;
end $$;

-- ═══ 5. 관리 작업 ═══════════════════════════════════════════════════
-- 이용 제한 / 해제
create or replace function public.seeon_admin_block(p_user uuid, p_block boolean, p_reason text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.seeon_admin_guard();
  if p_user = auth.uid() then raise exception '내 계정은 제한할 수 없어요.'; end if;
  if p_block then
    if exists (select 1 from public.seeon_admins where user_id = p_user) then raise exception '관리자 계정은 제한할 수 없어요. 먼저 관리자에서 해제하세요.'; end if;
    insert into public.seeon_blocked (user_id, reason, created_by) values (p_user, left(p_reason, 200), auth.uid())
      on conflict (user_id) do update set reason = excluded.reason, created_by = excluded.created_by, created_at = now();
  else
    delete from public.seeon_blocked where user_id = p_user;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 조종사(아이) 하나 삭제 (그 아이의 기록도 함께 삭제)
create or replace function public.seeon_admin_delete_profile(p_profile bigint) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  perform public.seeon_admin_guard();
  delete from public.seeon_profiles where id = p_profile;
  get diagnostics n = row_count;
  if n = 0 then raise exception '조종사를 찾을 수 없어요.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- 계정 삭제: p_mode = 'data' (게임 기록만 삭제) | 'account' (로그인 계정까지 삭제)
create or replace function public.seeon_admin_delete_user(p_user uuid, p_mode text default 'data') returns jsonb
language plpgsql volatile security definer set search_path = public, auth as $$
begin
  perform public.seeon_admin_guard();
  if p_user = auth.uid() then raise exception '내 계정은 여기서 삭제할 수 없어요.'; end if;
  if exists (select 1 from public.seeon_admins where user_id = p_user) then raise exception '관리자 계정은 삭제할 수 없어요. 먼저 관리자에서 해제하세요.'; end if;
  delete from public.seeon_profiles where user_id = p_user;   -- 기록은 함께 삭제됨
  if p_mode = 'account' then
    begin
      delete from auth.users where id = p_user;
    exception when others then
      raise exception '게임 기록은 지웠지만 로그인 계정은 지우지 못했어요. Supabase → Authentication → Users 에서 삭제해 주세요. (%)', sqlerrm;
    end;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 관리자 추가 / 해제 (이메일로)
create or replace function public.seeon_admin_set_admin(p_email text, p_on boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, auth as $$
declare uid uuid;
begin
  perform public.seeon_admin_guard();
  select id into uid from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if uid is null then raise exception '그 이메일로 가입한 계정이 없어요. 먼저 그 계정으로 한 번 로그인해야 해요.'; end if;
  if p_on then
    insert into public.seeon_admins (user_id) values (uid) on conflict do nothing;
    delete from public.seeon_blocked where user_id = uid;
  else
    if uid = auth.uid() then raise exception '내 관리자 권한은 스스로 해제할 수 없어요.'; end if;
    delete from public.seeon_admins where user_id = uid;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 관리자 목록
create or replace function public.seeon_admin_admins() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  perform public.seeon_admin_guard();
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'name', public.seeon_uname(u),
      'provider', coalesce(nullif(u.raw_app_meta_data->>'provider', ''), 'email'), 'since', a.created_at,
      'me', u.id = auth.uid()) order by a.created_at), '[]')
    into r from public.seeon_admins a join auth.users u on u.id = a.user_id;
  return r;
end $$;

-- ── 실행 권한: 로그인한 사용자만 호출 가능 (관리자 여부는 함수 안에서 확인) ──
do $$
declare f text;
begin
  foreach f in array array[
    'seeon_is_admin()', 'seeon_is_blocked()', 'seeon_me_status()', 'seeon_admin_guard()',
    'seeon_admin_overview(int)', 'seeon_admin_game(text, text, int)', 'seeon_admin_users(text, text, int, int)',
    'seeon_admin_user(uuid)', 'seeon_admin_block(uuid, boolean, text)', 'seeon_admin_delete_profile(bigint)',
    'seeon_admin_delete_user(uuid, text)', 'seeon_admin_set_admin(text, boolean)', 'seeon_admin_admins()',
    'seeon_kday(timestamptz)', 'seeon_gkey(text)', 'seeon_uname(auth.users)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ═══ 첫 관리자 지정 ═══════════════════════════════════════════════════
--  1) Supabase → Authentication → Users → "Add user → Create new user"
--     이메일·비밀번호 입력, "Auto Confirm User" 체크 → Create
--  2) 아래 이메일을 그 주소로 바꾼 뒤, 이 두 줄만 선택해서 Run
--
-- insert into public.seeon_admins (user_id)
--   select id from auth.users where email = 'admin@example.com' on conflict do nothing;
