-- ═══════════════════════════════════════════════════════════════════
--  SeeON 설치 상태 점검 (읽기 전용 · 아무것도 바꾸지 않아요)
--  Supabase → SQL Editor 에 붙여넣고 Run → 결과 표에서 '❌' 줄만 보면 돼요.
--  비밀번호·쿠폰 번호 원문은 나오지 않아요 (쿠폰은 개수만).
-- ═══════════════════════════════════════════════════════════════════
with want_fn(name) as (values
    ('seeon_admin_admins'),
    ('seeon_admin_block'),
    ('seeon_admin_consents'),
    ('seeon_admin_coupon_find'),
    ('seeon_admin_coupon_list'),
    ('seeon_admin_coupon_set'),
    ('seeon_admin_coupons'),
    ('seeon_admin_delete_profile'),
    ('seeon_admin_delete_user'),
    ('seeon_admin_exempt'),
    ('seeon_admin_game'),
    ('seeon_admin_guard'),
    ('seeon_admin_marketing'),
    ('seeon_admin_overview'),
    ('seeon_admin_research'),
    ('seeon_admin_set_admin'),
    ('seeon_admin_setting'),
    ('seeon_admin_user'),
    ('seeon_admin_users'),
    ('seeon_attach_eye'),
    ('seeon_consent_accept'),
    ('seeon_consent_status'),
    ('seeon_consent_sync'),
    ('seeon_coupon_after_signup'),
    ('seeon_coupon_check'),
    ('seeon_coupon_eval'),
    ('seeon_coupon_grace'),
    ('seeon_coupon_hash'),
    ('seeon_coupon_hash_v1'),
    ('seeon_coupon_norm'),
    ('seeon_coupon_on_delete'),
    ('seeon_coupon_on_signup'),
    ('seeon_coupon_redeem'),
    ('seeon_coupon_strip'),
    ('seeon_coupon_wrap'),
    ('seeon_coupons_hash_in'),
    ('seeon_daykey'),
    ('seeon_delete_me'),
    ('seeon_delete_profile'),
    ('seeon_email_available'),
    ('seeon_email_hash'),
    ('seeon_email_hash_v1'),
    ('seeon_gkey'),
    ('seeon_is_admin'),
    ('seeon_is_blocked'),
    ('seeon_is_runlist'),
    ('seeon_kday'),
    ('seeon_keep_days'),
    ('seeon_mask_email'),
    ('seeon_me_status'),
    ('seeon_merge_state'),
    ('seeon_my_access'),
    ('seeon_num'),
    ('seeon_profiles_limit'),
    ('seeon_public_config'),
    ('seeon_set_eye'),
    ('seeon_set_marketing'),
    ('seeon_set_research'),
    ('seeon_set_vision'),
    ('seeon_setting'),
    ('seeon_sync'),
    ('seeon_uname'),
    ('seeon_union_by')
), want_tb(name) as (values
    ('seeon_admins'),
    ('seeon_blocked'),
    ('seeon_consents'),
    ('seeon_coupon_exempt'),
    ('seeon_coupon_fails'),
    ('seeon_coupon_secret'),
    ('seeon_coupons'),
    ('seeon_entitlements'),
    ('seeon_profiles'),
    ('seeon_records'),
    ('seeon_research_salt'),
    ('seeon_settings')
), chk as (
  select '함수 '||w.name as item,
         case when exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=w.name)
              then '✅' else '❌ 없음' end as result
  from want_fn w
  union all
  select '표 '||w.name,
         case when to_regclass('public.'||w.name) is not null then '✅' else '❌ 없음' end
  from want_tb w
  union all
  select '우주 모험 기록 합치기 규칙 (schema.sql 최신판)',
         case when exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='seeon_merge_state' and position('seeon.story' in pg_get_functiondef(p.oid))>0)
              then '✅' else '❌ schema.sql 을 다시 Run 해 주세요' end
  union all
  select '도서 쿠폰 BOOK1 개수',
         case when to_regclass('public.seeon_coupons') is null then '❌ coupons.sql 먼저'
              else (select case when count(*)=1100 then '✅ 1100개' else '⚠️ '||count(*)||'개 (1100개여야 해요)' end from public.seeon_coupons where batch='BOOK1') end
  union all
  select '쿠폰 해시 강화 (비밀값 · 감싼 해시)',
         case when to_regclass('public.seeon_coupon_secret') is null then '❌ coupons.sql 을 다시 Run 해 주세요'
              when not exists (select 1 from public.seeon_coupon_secret where id = 1) then '❌ 비밀값 없음 — coupons.sql 을 다시 Run 해 주세요'
              when not exists (select 1 from pg_attribute where attrelid = 'public.seeon_coupons'::regclass and attname = 'hash_v' and not attisdropped) then '❌ hash_v 열 없음'
              when exists (select 1 from pg_trigger where tgrelid = 'public.seeon_coupons'::regclass and tgname = 'seeon_coupons_hash_in') is not true then '❌ 넣기 트리거 없음'
              else (select case when count(*) filter (where hash_v <> 2) = 0 then '✅ 전부 감쌈 ('||count(*)||'개)'
                                else '❌ 안 감싼 쿠폰 '||count(*) filter (where hash_v <> 2)||'개 — coupons.sql 을 다시 Run' end
                    from public.seeon_coupons) end
  union all
  select '쿠폰 비밀값·해시 함수 비공개 (anon·authenticated)',
         case when to_regclass('public.seeon_coupon_secret') is null or to_regprocedure('public.seeon_coupon_wrap(text)') is null then '❌ coupons.sql 을 다시 Run 해 주세요'
              when has_table_privilege('anon', 'public.seeon_coupon_secret', 'select') or has_table_privilege('authenticated', 'public.seeon_coupon_secret', 'select')
                or has_function_privilege('anon', 'public.seeon_coupon_hash(text)', 'execute') or has_function_privilege('authenticated', 'public.seeon_coupon_hash(text)', 'execute')
                or has_function_privilege('anon', 'public.seeon_email_hash(text)', 'execute') or has_function_privilege('authenticated', 'public.seeon_email_hash(text)', 'execute')
                or has_function_privilege('anon', 'public.seeon_coupon_wrap(text)', 'execute') or has_function_privilege('authenticated', 'public.seeon_coupon_wrap(text)', 'execute')
              then '❌ 권한이 열려 있어요 — coupons.sql 을 다시 Run' else '✅' end
)
select item as "점검 항목", result as "결과" from chk
order by (result like '✅%') , item;
