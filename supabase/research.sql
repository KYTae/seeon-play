-- ═══════════════════════════════════════════════════════════════════
--  SeeON 연구 활용 동의(선택) — 시기능 훈련·연구 플랫폼을 위한 별도 동의
--  schema.sql · admin.sql · members.sql · eye.sql 다음에 실행 (여러 번 실행해도 안전)
--  Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣고 Run
--
--  ▸ 게임 기록(seeon_records.m.d: 판 요약·게임별 변수)은 서비스·보호자 리포트를 위해 모든 회원에게 저장돼요.
--  ▸ 그중 '연구에 쓰는 것'은 보호자가 이 동의를 한 계정의 기록만이에요 (연구용 추출은 이 동의로 걸러요).
--  ▸ 철회하면 그 뒤로는 연구 추출에서 빠져요. (앞으로 만들 시행 단위 기록 seeon_trials 는 철회 시 삭제)
-- ═══════════════════════════════════════════════════════════════════

-- 동의 종류에 research 추가
alter table public.seeon_consents drop constraint if exists seeon_consents_kind_check;
alter table public.seeon_consents add constraint seeon_consents_kind_check
  check (kind in ('terms','privacy','age14','guardian','marketing_email','eye_metrics','vision_results','research'));

-- 내 동의 상태 (research / research_at 추가)
create or replace function public.seeon_consent_status(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'version', (select version from public.seeon_consents where user_id = p_user and kind = 'terms' order by created_at desc limit 1),
    'agreed_at', (select min(created_at) from public.seeon_consents where user_id = p_user and kind = 'terms'),
    'marketing', coalesce((select agreed from public.seeon_consents where user_id = p_user and kind = 'marketing_email' order by created_at desc, id desc limit 1), false),
    'marketing_at', (select created_at from public.seeon_consents where user_id = p_user and kind = 'marketing_email' order by created_at desc, id desc limit 1),
    'eye', coalesce((select agreed from public.seeon_consents where user_id = p_user and kind = 'eye_metrics' order by created_at desc, id desc limit 1), false),
    'eye_at', (select created_at from public.seeon_consents where user_id = p_user and kind = 'eye_metrics' order by created_at desc, id desc limit 1),
    'vision', coalesce((select agreed from public.seeon_consents where user_id = p_user and kind = 'vision_results' order by created_at desc, id desc limit 1), false),
    'vision_at', (select created_at from public.seeon_consents where user_id = p_user and kind = 'vision_results' order by created_at desc, id desc limit 1),
    'research', coalesce((select agreed from public.seeon_consents where user_id = p_user and kind = 'research' order by created_at desc, id desc limit 1), false),
    'research_at', (select created_at from public.seeon_consents where user_id = p_user and kind = 'research' order by created_at desc, id desc limit 1))
$$;

-- 가입 때 받은 동의 기록 (연구 활용 동의 포함)
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
    if coalesce(c->>'research', '') = 'true' then
      insert into public.seeon_consents (user_id, kind, agreed, version, created_at) values (uid, 'research', true, v, created);
    end if;
  end if;
  return public.seeon_consent_status(uid);
end $$;

-- 연구 활용 동의 / 철회
create or replace function public.seeon_set_research(p_on boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); v text;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  select version into v from public.seeon_consents where user_id = uid and kind = 'terms' order by created_at desc limit 1;
  insert into public.seeon_consents (user_id, kind, agreed, version) values (uid, 'research', coalesce(p_on, false), coalesce(v, 'unknown'));
  return public.seeon_consent_status(uid);
end $$;

revoke all on function public.seeon_consent_status(uuid) from public, anon, authenticated;
revoke all on function public.seeon_consent_sync() from public, anon;
grant execute on function public.seeon_consent_sync() to authenticated;
revoke all on function public.seeon_set_research(boolean) from public, anon;
grant execute on function public.seeon_set_research(boolean) to authenticated;
