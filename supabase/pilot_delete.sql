-- ═══════════════════════════════════════════════════════════════════
--  SeeON 조종사 지우기 — 계정 창 "🗑 조종사 지우기" 버튼이 부르는 함수
--  schema.sql · members.sql 다음에 실행 (여러 번 실행해도 안전)
--  Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣고 Run
--  (members.sql 끝에도 같은 함수가 들어 있어요 — 둘 중 하나만 실행해도 돼요)
-- ═══════════════════════════════════════════════════════════════════
-- 내 계정의 조종사 한 명과 그 조종사의 훈련 기록(seeon_records, on delete cascade)을 지워요.
-- 돌려주는 값: 남은 조종사 수
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
