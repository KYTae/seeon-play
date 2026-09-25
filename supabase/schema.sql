-- ═══════════════════════════════════════════════════════════════════
--  SeeON 웹 게임 — Supabase DB 스키마 (한 번만 실행)
--  Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣고 Run
--  여러 번 실행해도 안전하도록 작성되어 있습니다.
-- ═══════════════════════════════════════════════════════════════════

-- ── 조종사(아이) 프로필 ─────────────────────────────────────────────
create table if not exists public.seeon_profiles (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nickname    text not null check (char_length(nickname) between 1 and 40),
  avatar      int  not null default 1 check (avatar between 0 and 20),
  level       int  not null default 1,
  xp          int  not null default 0,
  state       jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists seeon_profiles_user_idx on public.seeon_profiles(user_id);

-- ── 게임 한 판 기록 ─────────────────────────────────────────────────
create table if not exists public.seeon_records (
  id          bigint generated always as identity primary key,
  profile_id  bigint not null references public.seeon_profiles(id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  cid         text not null check (char_length(cid) between 4 and 40),
  game_key    text not null,
  game_name   text,
  stage       int,
  stars       int,
  dur         int,
  xp          int,
  m           jsonb not null default '{}'::jsonb,   -- 분석용 숫자 지표
  metrics     jsonb not null default '{}'::jsonb,   -- 결과 화면 표시용 텍스트
  played_at   timestamptz not null,
  created_at  timestamptz not null default now(),
  unique (profile_id, cid)
);
create index if not exists seeon_records_profile_time_idx on public.seeon_records(profile_id, played_at);

-- ── 보안: 내 계정의 데이터만 읽고 쓸 수 있음 (Row Level Security) ─────
alter table public.seeon_profiles enable row level security;
alter table public.seeon_records  enable row level security;

drop policy if exists "seeon_profiles_own" on public.seeon_profiles;
create policy "seeon_profiles_own" on public.seeon_profiles
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "seeon_records_own" on public.seeon_records;
create policy "seeon_records_own" on public.seeon_records
  for all to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.seeon_profiles p where p.id = profile_id and p.user_id = auth.uid())
  );

revoke all on public.seeon_profiles, public.seeon_records from anon;
grant select, insert, update, delete on public.seeon_profiles, public.seeon_records to authenticated;

-- ── 계정당 조종사 최대 6명 ───────────────────────────────────────────
create or replace function public.seeon_profiles_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.seeon_profiles where user_id = new.user_id) >= 6 then
    raise exception '조종사는 계정당 6명까지 만들 수 있어요.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists seeon_profiles_limit on public.seeon_profiles;
create trigger seeon_profiles_limit before insert on public.seeon_profiles
  for each row execute function public.seeon_profiles_limit();

-- ── 도우미: jsonb 값 → 숫자 ──────────────────────────────────────────
create or replace function public.seeon_num(v jsonb) returns numeric
language sql immutable as $$
  select case
    when v is null then 0
    when jsonb_typeof(v) = 'number' then (v #>> '{}')::numeric
    when jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (v #>> '{}')::numeric
    else 0 end
$$;

-- 날짜 키("2026-9-25") 정렬용
create or replace function public.seeon_daykey(k text) returns int
language sql immutable as $$
  select case when k ~ '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$'
    then split_part(k,'-',1)::int * 10000 + split_part(k,'-',2)::int * 100 + split_part(k,'-',3)::int
    else 0 end
$$;

-- 최근 n일만 남기기 (객체의 날짜 키 기준)
create or replace function public.seeon_keep_days(o jsonb, n int) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  from (select key, value from jsonb_each(o) order by public.seeon_daykey(key) desc limit n) t
$$;

-- {v, when} 목록인지
create or replace function public.seeon_is_runlist(v jsonb) returns boolean
language sql immutable as $$
  select jsonb_typeof(v) = 'array' and not exists (
    select 1 from jsonb_array_elements(v) e
    where jsonb_typeof(e) <> 'object' or not (e ? 'when') or not (e ? 'v'))
$$;

-- 배열 두 개를 key 필드 기준으로 합치고(같으면 b 우선) key 순 정렬, 마지막 n개
create or replace function public.seeon_union_by(a jsonb, b jsonb, fld text, n int) returns jsonb
language sql immutable as $$
  with allx as (
    select e, 0 as src from jsonb_array_elements(a) e where jsonb_typeof(e) = 'object' and e ? fld
    union all
    select e, 1 as src from jsonb_array_elements(b) e where jsonb_typeof(e) = 'object' and e ? fld
  ), dedup as (
    select distinct on (public.seeon_num(e->fld)) e, public.seeon_num(e->fld) as k
    from allx order by public.seeon_num(e->fld), src desc
  ), lastn as (
    select e, k from dedup order by k desc limit n
  )
  select coalesce(jsonb_agg(e order by k), '[]'::jsonb) from lastn
$$;

-- ── 진행 상태 병합 규칙 (여러 기기에서 해도 좋은 기록이 사라지지 않게) ──
create or replace function public.seeon_merge_state(srv jsonb, cli jsonb) returns jsonb
language plpgsql immutable as $$
declare
  out_ jsonb := case when jsonb_typeof(srv) = 'object' then srv else '{}'::jsonb end;
  k text; a jsonb; b jsonb; v jsonb; a_hi boolean; day text; hv jsonb; tmp jsonb;
begin
  if cli is null or jsonb_typeof(cli) <> 'object' then return out_; end if;
  for k, b in select * from jsonb_each(cli) loop
    -- 기기 전용 키 / seeon. 이 아닌 키는 저장하지 않음
    if k not like 'seeon.%' or k in ('seeon.sound', 'seeon.records') or k like 'seeon.cloud.%' then continue; end if;
    a := out_ -> k;
    if a is null or jsonb_typeof(a) = 'null' then v := b;
    elsif b is null or jsonb_typeof(b) = 'null' then v := a;
    elsif k = 'seeon.profile' and jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
      -- 레벨·경험치는 높은 쪽, 이름·아바타는 새로 보낸 쪽
      a_hi := public.seeon_num(a->'lv') > public.seeon_num(b->'lv')
           or (public.seeon_num(a->'lv') = public.seeon_num(b->'lv') and public.seeon_num(a->'xp') > public.seeon_num(b->'xp'));
      v := (a || b) || jsonb_build_object(
             'lv', case when a_hi then public.seeon_num(a->'lv') else public.seeon_num(b->'lv') end,
             'xp', case when a_hi then public.seeon_num(a->'xp') else public.seeon_num(b->'xp') end);
    elsif k like 'seeon.stars.%' or k like 'seeon.unlock.%' or k = 'seeon.stellar' then
      v := to_jsonb(greatest(public.seeon_num(a), public.seeon_num(b)));
    elsif k = 'seeon.breaks' and jsonb_typeof(a) = 'array' and jsonb_typeof(b) = 'array' then
      v := public.seeon_union_by(a, b, 'at', 400);
    elsif k = 'seeon.habits' and jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
      tmp := a;
      for day, hv in select * from jsonb_each(b) loop
        if jsonb_typeof(hv) = 'object' then
          tmp := jsonb_set(tmp, array[day], coalesce((
            select jsonb_object_agg(h, (coalesce(tmp->day->h, 'false'::jsonb) = 'true'::jsonb or coalesce(hv->h, 'false'::jsonb) = 'true'::jsonb))
            from (select jsonb_object_keys(coalesce(tmp->day, '{}'::jsonb)) h union select jsonb_object_keys(hv)) hs
          ), '{}'::jsonb), true);
        end if;
      end loop;
      v := public.seeon_keep_days(tmp, 120);
    elsif k = 'seeon.screen' and jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
      -- 날짜별 화면 시간: 더 큰 값
      select coalesce(jsonb_object_agg(d, to_jsonb(greatest(public.seeon_num(a->d), public.seeon_num(b->d)))), '{}'::jsonb)
        into tmp
        from (select jsonb_object_keys(a) d union select jsonb_object_keys(b)) ds;
      v := public.seeon_keep_days(tmp, 120);
    elsif public.seeon_is_runlist(a) and public.seeon_is_runlist(b) then
      v := public.seeon_union_by(a, b, 'when', 12);
    else
      v := b;
    end if;
    out_ := jsonb_set(out_, array[k], v, true);
  end loop;
  return out_;
end $$;

-- ── 동기화: 기록 올리기 + 상태 병합 + (선택) 전체 기록 받기 ────────────
create or replace function public.seeon_sync(
  p_profile bigint,
  p_records jsonb default '[]'::jsonb,
  p_state jsonb default null,
  p_want boolean default false
) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  prof public.seeon_profiles%rowtype;
  n_saved int := 0; n_total int; merged jsonb; recs jsonb; pp jsonb;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  select * into prof from public.seeon_profiles where id = p_profile and user_id = auth.uid() for update;
  if not found then raise exception '조종사 프로필을 찾을 수 없어요.' using errcode = 'P0002'; end if;
  if jsonb_typeof(p_records) = 'array' and jsonb_array_length(p_records) > 300 then
    raise exception '한 번에 300판까지만 올릴 수 있어요.' using errcode = '22023';
  end if;

  if jsonb_typeof(p_records) = 'array' and jsonb_array_length(p_records) > 0 then
    with ins as (
      insert into public.seeon_records (profile_id, user_id, cid, game_key, game_name, stage, stars, dur, xp, m, metrics, played_at)
      select p_profile, auth.uid(),
             left(r->>'cid', 40),
             left(coalesce(r->>'key', 'unknown'), 40),
             left(r->>'game', 60),
             case when jsonb_typeof(r->'stage') = 'number' then (r->>'stage')::numeric::int end,
             case when jsonb_typeof(r->'stars') = 'number' then (r->>'stars')::numeric::int end,
             case when jsonb_typeof(r->'dur')   = 'number' then round((r->>'dur')::numeric)::int end,
             case when jsonb_typeof(r->'xp')    = 'number' then round((r->>'xp')::numeric)::int end,
             case when jsonb_typeof(r->'m') = 'object' then r->'m' else '{}'::jsonb end,
             case when jsonb_typeof(r->'metrics') = 'object' then r->'metrics' else '{}'::jsonb end,
             to_timestamp(public.seeon_num(r->'at') / 1000.0)
      from jsonb_array_elements(p_records) r
      where char_length(coalesce(r->>'cid', '')) between 4 and 40 and public.seeon_num(r->'at') > 0
      on conflict (profile_id, cid) do nothing
      returning 1
    ) select count(*) into n_saved from ins;
  end if;

  merged := coalesce(prof.state, '{}'::jsonb);
  if p_state is not null and jsonb_typeof(p_state) = 'object' then
    merged := public.seeon_merge_state(merged, p_state);
    pp := coalesce(merged->'seeon.profile', '{}'::jsonb);
    update public.seeon_profiles set
      state = merged,
      level = greatest(1, coalesce(nullif(public.seeon_num(pp->'lv'), 0)::int, prof.level)),
      xp = public.seeon_num(pp->'xp')::int,
      nickname = coalesce(nullif(left(pp->>'nick', 40), ''), prof.nickname),
      avatar = case when jsonb_typeof(pp->'ava') = 'number' then least(20, greatest(0, (pp->>'ava')::numeric::int)) else prof.avatar end,
      updated_at = now()
    where id = p_profile;
  end if;

  select count(*) into n_total from public.seeon_records where profile_id = p_profile;

  if p_want then
    select coalesce(jsonb_agg(x order by at_ms), '[]'::jsonb) into recs from (
      select jsonb_build_object(
        'cid', cid, 'key', game_key, 'game', game_name, 'stage', stage, 'stars', stars,
        'dur', dur, 'xp', xp, 'm', m, 'metrics', metrics,
        'at', floor(extract(epoch from played_at) * 1000)::bigint) as x,
        played_at as at_ms
      from public.seeon_records where profile_id = p_profile
      order by played_at desc limit 3000
    ) t;
  end if;

  return jsonb_build_object('saved', n_saved, 'total', n_total, 'state', merged, 'records', recs);
end $$;

revoke all on function public.seeon_sync(bigint, jsonb, jsonb, boolean) from public, anon;
grant execute on function public.seeon_sync(bigint, jsonb, jsonb, boolean) to authenticated;

-- ── 권한: "Automatically expose new tables" 를 꺼도 동작하도록 필요한 것만 명시적으로 허용 ──
revoke all on function public.seeon_merge_state(jsonb, jsonb), public.seeon_num(jsonb), public.seeon_daykey(text),
  public.seeon_keep_days(jsonb, int), public.seeon_is_runlist(jsonb), public.seeon_union_by(jsonb, jsonb, text, int),
  public.seeon_profiles_limit() from public, anon;
grant execute on function public.seeon_merge_state(jsonb, jsonb), public.seeon_num(jsonb), public.seeon_daykey(text),
  public.seeon_keep_days(jsonb, int), public.seeon_is_runlist(jsonb), public.seeon_union_by(jsonb, jsonb, text, int)
  to authenticated;
grant usage on schema public to authenticated;
