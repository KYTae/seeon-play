-- ═══════════════════════════════════════════════════════════════════
--  SeeON 연구용 자료 내려받기 (관리자 전용)
--  Supabase → SQL Editor 에 붙여넣고 Run (여러 번 실행해도 안전해요)
--  먼저 admin.sql · research.sql 이 실행되어 있어야 해요.
--
--  · 연구 활용 동의(research)가 켜진 계정의 기록만 돌려줘요.
--  · 이메일·이름·별명은 돌려주지 않아요. 계정·조종사는 가명 ID로 바꿔요.
--    가명 ID = 비밀값(salt) + 원래 ID 의 해시 앞 12자리.
--    같은 사람은 언제 내려받아도 같은 가명 ID라서 시간에 따른 변화를 볼 수 있어요.
--    비밀값은 아래 표에만 있고 관리자 화면·내려받은 파일에는 나오지 않아요.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.seeon_research_salt (
  id         int primary key default 1 check (id = 1),
  salt       text not null default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);
alter table public.seeon_research_salt enable row level security;   -- 정책 없음: 누구도 직접 읽을 수 없어요
revoke all on public.seeon_research_salt from public, anon, authenticated;
insert into public.seeon_research_salt (id) values (1) on conflict (id) do nothing;

-- p_from, p_to : 한국 날짜 (포함)
-- p_game       : '' 이면 모든 게임, 아니면 게임 키 (meteor, starcode …)
-- p_after      : 이어받기용 — 앞 묶음의 마지막 k 값 (처음엔 0)
create or replace function public.seeon_admin_research(
  p_from date, p_to date, p_game text default '', p_limit int default 1000, p_after bigint default 0)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare lim int := greatest(1, least(coalesce(p_limit, 1000), 2000)); r jsonb;
        s text := (select salt from public.seeon_research_salt where id = 1);
begin
  perform public.seeon_admin_guard();
  if s is null then raise exception 'research_export.sql 을 다시 실행해 주세요 (비밀값 없음).'; end if;
  with c as (
    select distinct on (user_id) user_id, agreed
    from public.seeon_consents where kind = 'research'
    order by user_id, created_at desc, id desc
  ), x as (
    select r.* from public.seeon_records r
    join c on c.user_id = r.user_id and c.agreed
    where public.seeon_kday(r.played_at) between p_from and p_to
      and (coalesce(p_game, '') = '' or public.seeon_gkey(r.game_key) = p_game)
      and r.id > coalesce(p_after, 0)
    order by r.id
    limit lim
  )
  select jsonb_build_object(
    'consented', (select count(*) from c where c.agreed),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
        'k',     x.id,
        'uid',   'U' || left(md5(s || ':u:' || x.user_id::text), 12),
        'pid',   'C' || left(md5(s || ':p:' || x.profile_id::text), 12),
        'game',  x.game_key,
        'stage', x.stage,
        'stars', x.stars,
        'dur',   x.dur,
        'at',    to_char(x.played_at at time zone 'Asia/Seoul', 'YYYY-MM-DD"T"HH24:MI:SS'),
        'm',     x.m) order by x.id), '[]'::jsonb)
  ) into r from x;
  return r;
end $$;

revoke all on function public.seeon_admin_research(date, date, text, int, bigint) from public, anon;
grant execute on function public.seeon_admin_research(date, date, text, int, bigint) to authenticated;
