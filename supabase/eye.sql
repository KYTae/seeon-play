-- ═══════════════════════════════════════════════════════════════════
--  SeeON 카메라 기능 — 선택 동의 (eye_metrics: 눈 움직임 요약 숫자 · vision_results: 시력 측정 기록)
--  members.sql 다음에 실행 (여러 번 실행해도 안전)
--
--  ▸ 카메라 영상은 기기(브라우저) 안에서만 분석하고 서버로 보내지 않아요.
--  ▸ 보호자가 따로 동의한 경우에만, 게임 기록(seeon_records.m)에
--    e_ 로 시작하는 요약 숫자(머리 고정 비율, 눈이 목표를 따라간 정도 등)를 함께 저장해요.
--  ▸ 동의를 철회하면 지금까지 저장된 e_ 숫자도 모두 지워요.
-- ═══════════════════════════════════════════════════════════════════

-- 동의 종류에 eye_metrics 추가
alter table public.seeon_consents drop constraint if exists seeon_consents_kind_check;
alter table public.seeon_consents add constraint seeon_consents_kind_check
  check (kind in ('terms','privacy','age14','guardian','marketing_email','eye_metrics','vision_results','research'));

-- 내 동의 상태 (eye / eye_at · vision / vision_at 추가)
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

-- 눈 움직임 측정 결과 저장 동의 / 철회 (철회하면 저장된 요약 숫자도 삭제)
create or replace function public.seeon_set_eye(p_on boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); v text;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  select version into v from public.seeon_consents where user_id = uid and kind = 'terms' order by created_at desc limit 1;
  insert into public.seeon_consents (user_id, kind, agreed, version) values (uid, 'eye_metrics', coalesce(p_on, false), coalesce(v, 'unknown'));
  if not coalesce(p_on, false) then
    update public.seeon_records
       set m = m - array['e_fv','e_hs','e_bl','e_fo','e_rg','e_cv','e_ch','e_sc','e_lt','e_q','e_n']
     where user_id = uid and m ?| array['e_fv','e_hs','e_bl','e_fo','e_rg','e_cv','e_ch','e_sc','e_lt','e_q','e_n'];
  end if;
  return public.seeon_consent_status(uid);
end $$;

revoke all on function public.seeon_set_eye(boolean) from public, anon;
grant execute on function public.seeon_set_eye(boolean) to authenticated;

-- 결과 화면에서 나중에 "이 결과 저장하기"를 눌렀을 때: 이미 올라간 게임 기록(cid)에 e_ 요약 숫자만 붙여요
--  ▸ 저장 동의(eye_metrics)가 켜져 있어야 하고, 내 기록에만, e_ 로 시작하는 정해진 숫자 키만 받아요
drop function if exists public.seeon_attach_eye(uuid, text, jsonb);
create or replace function public.seeon_attach_eye(p_profile bigint, p_cid text, p_m jsonb) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); clean jsonb; n int;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  if not coalesce((select agreed from public.seeon_consents where user_id = uid and kind = 'eye_metrics' order by created_at desc, id desc limit 1), false) then
    raise exception '눈 측정 결과 저장 동의가 필요해요.' using errcode = '42501';
  end if;
  if p_m is null or jsonb_typeof(p_m) <> 'object' then return false; end if;
  select coalesce(jsonb_object_agg(k, to_jsonb(round(public.seeon_num(v), 3))), '{}'::jsonb) into clean
    from jsonb_each(p_m) e(k, v)
   where k = any(array['e_fv','e_hs','e_bl','e_fo','e_rg','e_cv','e_ch','e_sc','e_lt','e_q','e_n']) and jsonb_typeof(v) = 'number';
  if clean = '{}'::jsonb then return false; end if;
  update public.seeon_records set m = coalesce(m, '{}'::jsonb) || clean
   where user_id = uid and profile_id = p_profile and cid = left(coalesce(p_cid, ''), 40);
  get diagnostics n = row_count;
  return n > 0;
end $$;

revoke all on function public.seeon_attach_eye(bigint, text, jsonb) from public, anon;
grant execute on function public.seeon_attach_eye(bigint, text, jsonb) to authenticated;

-- 👁️ 시력 측정 기록(seeon.vision)을 계정에 저장하는 동의 / 철회 (철회하면 모든 조종사의 계정 저장 기록 삭제)
create or replace function public.seeon_set_vision(p_on boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); v text;
begin
  if uid is null then raise exception '로그인이 필요해요.' using errcode = '28000'; end if;
  select version into v from public.seeon_consents where user_id = uid and kind = 'terms' order by created_at desc limit 1;
  insert into public.seeon_consents (user_id, kind, agreed, version) values (uid, 'vision_results', coalesce(p_on, false), coalesce(v, 'unknown'));
  if not coalesce(p_on, false) then
    update public.seeon_profiles set state = state - 'seeon.vision' where user_id = uid and state ? 'seeon.vision';
  end if;
  return public.seeon_consent_status(uid);
end $$;

revoke all on function public.seeon_set_vision(boolean) from public, anon;
grant execute on function public.seeon_set_vision(boolean) to authenticated;
