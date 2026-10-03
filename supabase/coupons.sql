-- ═══════════════════════════════════════════════════════════════════
--  SeeON 도서 쿠폰 등록 · 체험 제한
--  Supabase → SQL Editor 에 붙여넣고 Run (여러 번 실행해도 안전해요)
--  먼저 schema.sql · admin.sql 이 실행되어 있어야 해요.
--
--  · 회원가입은 누구나 할 수 있어요. 로그인한 뒤 '쿠폰 등록'을 하면 모든 단계가 열려요.
--    (가입 화면에서 쿠폰을 넣으면 가입과 동시에 등록돼요)
--  · 쿠폰을 등록하지 않은 회원과 비회원은 체험 범위(기본: 게임마다 2단계, 우주 모험 10번째 행성)까지만.
--  · 이 SQL 을 처음 실행할 때 이미 가입해 있던 계정은 '기존 회원'으로 쿠폰 없이 전체 이용해요.
--  · 쿠폰 번호 원문은 저장하지 않아요. 해시(sha256)만 저장해요.
--    쿠폰 넣기는 tools/make_coupons.py 가 만든 coupons_<묶음>_insert.sql 로 해요.
--  · 관리자 화면 '쿠폰' 탭에서 켜고 끌 수 있어요: 쿠폰 등록해야 전체 이용 / 체험 제한.
-- ═══════════════════════════════════════════════════════════════════

-- ── 설정 ─────────────────────────────────────────────────────────────
create table if not exists public.seeon_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.seeon_settings enable row level security;
revoke all on public.seeon_settings from public, anon, authenticated;
insert into public.seeon_settings (key, value) values
  ('coupon_required', 'true'::jsonb),     -- 쿠폰을 등록해야 전체 이용 (끄면 모든 회원이 전체 이용)
  ('guest_limit',     'true'::jsonb),     -- 체험 제한 (비회원 · 쿠폰 미등록 회원)
  ('guest_max_stage', '2'::jsonb),        -- 체험으로 할 수 있는 최고 단계
  ('guest_story_max', '10'::jsonb)        -- 체험으로 할 수 있는 우주 모험 스테이지
on conflict (key) do nothing;

create or replace function public.seeon_setting(p_key text) returns jsonb
language sql stable security definer set search_path = public as $$
  select value from public.seeon_settings where key = p_key
$$;

-- 누구나 읽는 공개 설정 (게임 화면이 시작할 때 읽어요)
create or replace function public.seeon_public_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'coupon_required', coalesce((public.seeon_setting('coupon_required'))::text::boolean, true),
    'guest_limit',     coalesce((public.seeon_setting('guest_limit'))::text::boolean, true),
    'guest_max_stage', coalesce((public.seeon_setting('guest_max_stage'))::text::int, 2),
    'guest_story_max', coalesce((public.seeon_setting('guest_story_max'))::text::int, 10))
$$;

-- ── 쿠폰 ─────────────────────────────────────────────────────────────
create table if not exists public.seeon_coupons (
  id              bigint generated always as identity primary key,
  batch           text not null,                       -- 묶음 이름 (예: BOOK1)
  serial          int  not null,                       -- 묶음 안 일련번호 (인쇄용 목록과 같아요)
  code_hash       text not null unique,                -- sha256('seeon-coupon:' || 번호)
  status          text not null default 'new' check (status in ('new', 'used', 'blocked')),
  used_by         uuid,                                -- 쓴 계정 (계정을 지우면 비워져요)
  used_email_hash text,                                -- 쓴 이메일의 해시 (같은 이메일로 다시 가입할 때만 재사용)
  used_at         timestamptz,
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (batch, serial)
);
create index if not exists seeon_coupons_used_by on public.seeon_coupons (used_by);
alter table public.seeon_coupons enable row level security;   -- 정책 없음: 함수로만 읽고 써요
revoke all on public.seeon_coupons from public, anon, authenticated;

create table if not exists public.seeon_coupon_exempt (
  email      text primary key,
  note       text,
  created_at timestamptz not null default now()
);
alter table public.seeon_coupon_exempt enable row level security;
revoke all on public.seeon_coupon_exempt from public, anon, authenticated;

-- 전체 이용 권한 (coupon: 쿠폰 등록 · legacy: 이 기능 전에 가입한 기존 회원)
create table if not exists public.seeon_entitlements (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  source     text not null check (source in ('coupon', 'legacy')),
  coupon_id  bigint,
  created_at timestamptz not null default now()
);
alter table public.seeon_entitlements enable row level security;
revoke all on public.seeon_entitlements from public, anon, authenticated;

-- 쿠폰 등록 실패 기록 (같은 계정이 번호를 마구 넣어 보는 것을 막아요)
create table if not exists public.seeon_coupon_fails (
  id      bigint generated always as identity primary key,
  user_id uuid not null,
  at      timestamptz not null default now()
);
create index if not exists seeon_coupon_fails_user on public.seeon_coupon_fails (user_id, at);
alter table public.seeon_coupon_fails enable row level security;
revoke all on public.seeon_coupon_fails from public, anon, authenticated;

-- 처음 실행할 때 한 번만: 이미 가입해 있던 계정은 '기존 회원'으로 전체 이용
do $$ begin
  if not exists (select 1 from public.seeon_settings where key = 'legacy_granted') then
    insert into public.seeon_entitlements (user_id, source)
      select id, 'legacy' from auth.users on conflict (user_id) do nothing;
    insert into public.seeon_settings (key, value) values ('legacy_granted', to_jsonb(now()));
  end if;
end $$;

-- 번호 정리: 공백·하이픈 빼고 대문자
create or replace function public.seeon_coupon_norm(p text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) $$;

create or replace function public.seeon_coupon_hash(p text) returns text
language sql immutable as $$ select encode(sha256(convert_to('seeon-coupon:' || public.seeon_coupon_norm(p), 'UTF8')), 'hex') $$;

create or replace function public.seeon_email_hash(p text) returns text
language sql immutable as $$ select encode(sha256(convert_to('seeon-email:' || lower(trim(coalesce(p, ''))), 'UTF8')), 'hex') $$;

-- 이메일 가리기 (ab***@gm***.com)
create or replace function public.seeon_mask_email(p text) returns text
language sql immutable as $$
  select case when p is null or position('@' in p) = 0 then null else
    left(split_part(p, '@', 1), 2) || '***@' || left(split_part(p, '@', 2), 2) || '***' ||
    coalesce('.' || nullif(reverse(split_part(reverse(split_part(p, '@', 2)), '.', 1)), split_part(p, '@', 2)), '') end
$$;

-- 인증하지 않은 가입을 기다려 주는 시간 (이메일 오타 → 다시 가입할 수 있게)
create or replace function public.seeon_coupon_grace() returns interval
language sql immutable as $$ select interval '20 minutes' $$;

-- 쿠폰 상태 판단 (내부용) — reason: ok · format · notfound · used · blocked · pending
create or replace function public.seeon_coupon_eval(p_code text, p_email text)
returns table (reason text, coupon_id bigint, stale_user uuid, wait_min int, holder_mask text)
language plpgsql stable security definer set search_path = public, auth as $$
declare n text := public.seeon_coupon_norm(p_code); c public.seeon_coupons; h auth.users;
begin
  if length(n) <> 12 or n ~ '[^23456789ABCDEFGHJKMNPQRSTVWXYZ]' then
    return query select 'format'::text, null::bigint, null::uuid, null::int, null::text; return; end if;
  select * into c from public.seeon_coupons where code_hash = public.seeon_coupon_hash(n);
  if not found then return query select 'notfound'::text, null::bigint, null::uuid, null::int, null::text; return; end if;
  if c.status = 'blocked' then return query select 'blocked'::text, c.id, null::uuid, null::int, null::text; return; end if;
  if c.status = 'new' then return query select 'ok'::text, c.id, null::uuid, null::int, null::text; return; end if;
  -- 사용됨
  if c.used_by is not null then select * into h from auth.users where id = c.used_by; end if;
  if h.id is null then
    -- 계정을 지운 쿠폰: 같은 이메일이면 다시 가입할 수 있어요
    if p_email is not null and c.used_email_hash = public.seeon_email_hash(p_email) then
      return query select 'ok'::text, c.id, null::uuid, null::int, null::text; return; end if;
    return query select 'used'::text, c.id, null::uuid, null::int, null::text; return;
  end if;
  if h.email_confirmed_at is null then
    if h.created_at < now() - public.seeon_coupon_grace() then
      return query select 'ok'::text, c.id, h.id, null::int, public.seeon_mask_email(h.email); return; end if;
    return query select 'pending'::text, c.id, null::uuid,
      greatest(1, ceil(extract(epoch from (h.created_at + public.seeon_coupon_grace() - now())) / 60)::int),
      public.seeon_mask_email(h.email); return;
  end if;
  return query select 'used'::text, c.id, null::uuid, null::int, null::text;
end $$;

-- 쿠폰 확인만 (가입 화면 · 쿠폰 등록 창에서 불러요, 로그인 전에도 가능)
create or replace function public.seeon_coupon_check(p_code text, p_email text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select * into r from public.seeon_coupon_eval(p_code, p_email);
  return jsonb_build_object('ok', r.reason = 'ok', 'reason', r.reason, 'wait_min', r.wait_min, 'holder', r.holder_mask,
    'required', coalesce((public.seeon_setting('coupon_required'))::text::boolean, true));
end $$;

-- 내 이용 범위: full = 모든 단계 · source = coupon / legacy(기존 회원) / exempt(예외 이메일) / open(쿠폰 등록 필수 꺼짐)
create or replace function public.seeon_my_access() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid := auth.uid(); em text; e public.seeon_entitlements; c public.seeon_coupons; src text;
begin
  if uid is null then return jsonb_build_object('member', false, 'full', false); end if;
  select email into em from auth.users where id = uid;
  select * into e from public.seeon_entitlements where user_id = uid;
  if e.user_id is not null then src := e.source;
    if e.coupon_id is not null then select * into c from public.seeon_coupons where id = e.coupon_id; end if;
  elsif em is not null and exists (select 1 from public.seeon_coupon_exempt x where x.email = lower(em)) then src := 'exempt';
  elsif not coalesce((public.seeon_setting('coupon_required'))::text::boolean, true) then src := 'open';
  end if;
  return jsonb_build_object('member', true, 'full', src is not null, 'source', src,
    'coupon', case when c.id is null then null else jsonb_build_object('batch', c.batch, 'serial', c.serial, 'at', e.created_at) end);
end $$;

-- 로그인한 회원의 쿠폰 등록
create or replace function public.seeon_coupon_redeem(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = public, auth as $$
declare uid uuid := auth.uid(); em text; n text := public.seeon_coupon_norm(p_code); h text; r record; fails int; own bigint;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  select email into em from auth.users where id = uid;
  if exists (select 1 from public.seeon_entitlements where user_id = uid) then
    return jsonb_build_object('ok', true, 'reason', 'already', 'access', public.seeon_my_access()); end if;
  select count(*) into fails from public.seeon_coupon_fails where user_id = uid and at > now() - interval '1 hour';
  if fails >= 20 then return jsonb_build_object('ok', false, 'reason', 'too_many'); end if;
  h := public.seeon_coupon_hash(n);
  perform 1 from public.seeon_coupons where code_hash = h for update;   -- 같은 쿠폰을 동시에 등록하면 한 명만
  select id into own from public.seeon_coupons where code_hash = h and used_by = uid and status = 'used';
  if own is null then
    select * into r from public.seeon_coupon_eval(n, em);
    if r.reason <> 'ok' then
      if r.reason in ('format', 'notfound') then insert into public.seeon_coupon_fails (user_id) values (uid); end if;
      return jsonb_build_object('ok', false, 'reason', r.reason, 'wait_min', r.wait_min, 'holder', r.holder_mask);
    end if;
    if r.stale_user is not null then delete from auth.users where id = r.stale_user and email_confirmed_at is null; end if;
    update public.seeon_coupons set status = 'used', used_by = uid, used_email_hash = public.seeon_email_hash(em), used_at = now(), updated_at = now()
     where id = r.coupon_id;
    own := r.coupon_id;
  end if;
  insert into public.seeon_entitlements (user_id, source, coupon_id) values (uid, 'coupon', own)
    on conflict (user_id) do update set source = 'coupon', coupon_id = excluded.coupon_id, created_at = now();
  return jsonb_build_object('ok', true, 'reason', 'ok', 'access', public.seeon_my_access());
end $$;

-- ── 가입 화면에서 쿠폰을 같이 넣은 경우: 가입과 동시에 등록 (쿠폰이 안 맞아도 가입은 그대로 돼요) ──
create or replace function public.seeon_coupon_on_signup() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare code text; r record;
begin
  code := public.seeon_coupon_norm(new.raw_user_meta_data ->> 'coupon');
  if new.raw_user_meta_data ? 'coupon' then new.raw_user_meta_data := new.raw_user_meta_data - 'coupon'; end if;   -- 번호 원문은 남기지 않아요
  if code = '' then return new; end if;
  begin
    perform 1 from public.seeon_coupons where code_hash = public.seeon_coupon_hash(code) for update;
    select * into r from public.seeon_coupon_eval(code, new.email);
    if r.reason = 'ok' then
      if r.stale_user is not null then delete from auth.users where id = r.stale_user and email_confirmed_at is null; end if;
      update public.seeon_coupons
         set status = 'used', used_by = new.id, used_email_hash = public.seeon_email_hash(new.email), used_at = now(), updated_at = now()
       where id = r.coupon_id;
    end if;
  exception when others then
    raise warning 'seeon coupon on signup: %', sqlerrm;   -- 쿠폰 처리에 문제가 있어도 가입은 막지 않아요 (로그인 뒤 다시 등록)
  end;
  return new;
end $$;

-- 계정이 만들어진 뒤: 가입 때 잡아 둔 쿠폰으로 전체 이용 권한
create or replace function public.seeon_coupon_after_signup() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  begin
    insert into public.seeon_entitlements (user_id, source, coupon_id)
      select new.id, 'coupon', c.id from public.seeon_coupons c where c.used_by = new.id and c.status = 'used' order by c.used_at desc limit 1
      on conflict (user_id) do nothing;
  exception when others then
    raise warning 'seeon coupon after signup: %', sqlerrm;
  end;
  return new;
end $$;

create or replace function public.seeon_coupon_strip() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.raw_user_meta_data ? 'coupon' then new.raw_user_meta_data := new.raw_user_meta_data - 'coupon'; end if;
  return new;
end $$;

create or replace function public.seeon_coupon_on_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.seeon_coupons set used_by = null, updated_at = now() where used_by = old.id;
  return old;
end $$;

drop trigger if exists seeon_coupon_on_signup on auth.users;
create trigger seeon_coupon_on_signup before insert on auth.users
  for each row execute function public.seeon_coupon_on_signup();
drop trigger if exists seeon_coupon_after_signup on auth.users;
create trigger seeon_coupon_after_signup after insert on auth.users
  for each row execute function public.seeon_coupon_after_signup();
drop trigger if exists seeon_coupon_strip on auth.users;
create trigger seeon_coupon_strip before update of raw_user_meta_data on auth.users
  for each row when (new.raw_user_meta_data ? 'coupon') execute function public.seeon_coupon_strip();
drop trigger if exists seeon_coupon_on_delete on auth.users;
create trigger seeon_coupon_on_delete after delete on auth.users
  for each row execute function public.seeon_coupon_on_delete();

-- ── 관리자 ───────────────────────────────────────────────────────────
create or replace function public.seeon_admin_coupons() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  perform public.seeon_admin_guard();
  select jsonb_build_object(
    'total',   (select count(*) from public.seeon_coupons),
    'new',     (select count(*) from public.seeon_coupons where status = 'new'),
    'used',    (select count(*) from public.seeon_coupons where status = 'used'),
    'blocked', (select count(*) from public.seeon_coupons where status = 'blocked'),
    'batches', (select coalesce(jsonb_agg(b order by b.batch), '[]') from (
        select batch, count(*) as total, count(*) filter (where status = 'used') as used,
               count(*) filter (where status = 'blocked') as blocked, min(serial) as s0, max(serial) as s1
        from public.seeon_coupons group by batch) b),
    'recent',  (select coalesce(jsonb_agg(x order by x.used_at desc), '[]') from (
        select c.batch, c.serial, c.used_at, u.email, (u.email_confirmed_at is not null) as confirmed
        from public.seeon_coupons c left join auth.users u on u.id = c.used_by
        where c.status = 'used' order by c.used_at desc limit 20) x),
    'exempt',  (select coalesce(jsonb_agg(e order by e.created_at), '[]') from (select email, note, created_at from public.seeon_coupon_exempt) e),
    'members', (select jsonb_build_object(
        'total',  count(*),
        'coupon', count(*) filter (where en.source = 'coupon'),
        'legacy', count(*) filter (where en.source = 'legacy'),
        'exempt', count(*) filter (where en.user_id is null and x.email is not null),
        'none',   count(*) filter (where en.user_id is null and x.email is null))
      from auth.users u left join public.seeon_entitlements en on en.user_id = u.id
      left join public.seeon_coupon_exempt x on x.email = lower(u.email)),
    'config',  public.seeon_public_config()
  ) into r;
  return r;
end $$;

-- 번호(XXXX-XXXX-XXXX) 또는 묶음-일련번호(BOOK1-0123)로 찾기
create or replace function public.seeon_admin_coupon_find(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare q text := trim(coalesce(p_q, '')); c public.seeon_coupons; u auth.users; m text[];
begin
  perform public.seeon_admin_guard();
  m := regexp_match(q, '^([A-Za-z0-9_]+)[-\s#]+0*([0-9]{1,6})$');
  if m is not null and length(public.seeon_coupon_norm(q)) <> 12 then
    select * into c from public.seeon_coupons where upper(batch) = upper(m[1]) and serial = m[2]::int;
  else
    select * into c from public.seeon_coupons where code_hash = public.seeon_coupon_hash(q);
  end if;
  if not found then return jsonb_build_object('found', false); end if;
  if c.used_by is not null then select * into u from auth.users where id = c.used_by; end if;
  return jsonb_build_object('found', true, 'id', c.id, 'batch', c.batch, 'serial', c.serial, 'status', c.status,
    'used_at', c.used_at, 'note', c.note, 'email', u.email, 'confirmed', u.email_confirmed_at is not null,
    'deleted', c.status = 'used' and c.used_by is null,
    'full', exists (select 1 from public.seeon_entitlements en where en.user_id = c.used_by));
end $$;

-- release: 다시 쓸 수 있게(쓴 계정은 그대로 유지) · block: 막기 · unblock: 막기 풀기
create or replace function public.seeon_admin_coupon_set(p_id bigint, p_action text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.seeon_admin_guard();
  if p_action = 'release' then
    update public.seeon_coupons set status = 'new', used_by = null, used_email_hash = null, used_at = null,
      note = coalesce(nullif(p_note, ''), note), updated_at = now() where id = p_id;
  elsif p_action = 'block' then
    update public.seeon_coupons set status = 'blocked', note = coalesce(nullif(p_note, ''), note), updated_at = now() where id = p_id;
  elsif p_action = 'unblock' then
    update public.seeon_coupons set status = case when used_email_hash is null then 'new' else 'used' end,
      note = coalesce(nullif(p_note, ''), note), updated_at = now() where id = p_id and status = 'blocked';
  else raise exception '알 수 없는 동작이에요.'; end if;
  if not found then raise exception '쿠폰을 찾지 못했어요.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- 사용 내역 (CSV 용)
create or replace function public.seeon_admin_coupon_list(p_batch text default '', p_status text default '') returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  perform public.seeon_admin_guard();
  select coalesce(jsonb_agg(jsonb_build_object('batch', c.batch, 'serial', c.serial, 'status', c.status, 'used_at', c.used_at,
      'email', u.email, 'confirmed', u.email_confirmed_at is not null, 'note', c.note) order by c.batch, c.serial), '[]')
    into r
  from public.seeon_coupons c left join auth.users u on u.id = c.used_by
  where (coalesce(p_batch, '') = '' or c.batch = p_batch) and (coalesce(p_status, '') = '' or c.status = p_status);
  return r;
end $$;

create or replace function public.seeon_admin_setting(p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.seeon_admin_guard();
  if p_key not in ('coupon_required', 'guest_limit', 'guest_max_stage', 'guest_story_max') then raise exception '알 수 없는 설정이에요.'; end if;
  if p_key in ('coupon_required', 'guest_limit') and jsonb_typeof(p_value) <> 'boolean' then raise exception '켜기/끄기 값이 필요해요.'; end if;
  if p_key in ('guest_max_stage', 'guest_story_max') and (jsonb_typeof(p_value) <> 'number' or (p_value::text)::int < 1) then raise exception '1 이상의 숫자가 필요해요.'; end if;
  insert into public.seeon_settings (key, value, updated_at) values (p_key, p_value, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.seeon_public_config();
end $$;

create or replace function public.seeon_admin_exempt(p_email text, p_on boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare em text := lower(trim(coalesce(p_email, '')));
begin
  perform public.seeon_admin_guard();
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception '이메일 형식을 확인해 주세요.'; end if;
  if p_on then insert into public.seeon_coupon_exempt (email, note) values (em, nullif(p_note, '')) on conflict (email) do nothing;
  else delete from public.seeon_coupon_exempt where email = em; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ── 실행 권한 ─────────────────────────────────────────────────────────
do $$
declare f text;
begin
  -- 내부용: 아무도 직접 부르지 못하게
  foreach f in array array['seeon_setting(text)', 'seeon_coupon_eval(text, text)', 'seeon_coupon_on_signup()',
                           'seeon_coupon_after_signup()', 'seeon_coupon_strip()', 'seeon_coupon_on_delete()']
  loop execute format('revoke all on function public.%s from public, anon, authenticated', f); end loop;
  -- 누구나 (가입 전 화면)
  foreach f in array array['seeon_public_config()', 'seeon_coupon_check(text, text)']
  loop execute format('revoke all on function public.%s from public', f);
       execute format('grant execute on function public.%s to anon, authenticated', f); end loop;
  -- 로그인한 회원
  foreach f in array array['seeon_my_access()', 'seeon_coupon_redeem(text)']
  loop execute format('revoke all on function public.%s from public, anon', f);
       execute format('grant execute on function public.%s to authenticated', f); end loop;
  -- 관리자 (함수 안에서 관리자인지 확인)
  foreach f in array array['seeon_admin_coupons()', 'seeon_admin_coupon_find(text)', 'seeon_admin_coupon_set(bigint, text, text)',
                           'seeon_admin_coupon_list(text, text)', 'seeon_admin_setting(text, jsonb)', 'seeon_admin_exempt(text, boolean, text)']
  loop execute format('revoke all on function public.%s from public, anon', f);
       execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;

-- ═══ 쿠폰 없이 전체 이용할 계정(관리자·시연용) 이메일 넣기 (필요하면 이메일을 바꿔서 Run) ═══
-- insert into public.seeon_coupon_exempt (email, note) values ('admin@example.com', '관리자') on conflict do nothing;
