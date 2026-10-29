-- ═══════════════════════════════════════════════════════════════════
--  🌈 무지개 별무리(cdots) 추가 뒤, 이미 만들어 둔 슈퍼 계정 조종사 보정 — Supabase SQL Editor 에서 한 번 실행
--  · 비밀번호가 들어 있지 않아요(저장소에 올려도 돼요). 여러 번 실행해도 괜찮아요.
--  · 조종사 '슈퍼 조종사' · '지도1 끝 연습' · '지도2 끝 연습' 에게 무지개 별무리 5단계 전부 열림·별 3개를 넣고,
--    '슈퍼 조종사'에게는 무지개 별무리 기록 5판(1~5단계 · 별 3개)을 더해요 → 게임 마스터(19종) 배지·별 대부호(243개) 배지가 그대로 유지돼요.
--  · 새로 만드는 슈퍼 계정은 tools/super_account.py 가 이미 이 칸까지 채우니 이 파일이 필요 없어요.
-- ═══════════════════════════════════════════════════════════════════
do $$
declare
  prof record; st jsonb; n int := 0; day0 date := (now() at time zone 'Asia/Seoul')::date;
begin
  for prof in select id, user_id, nickname, state from public.seeon_profiles
              where nickname in ('슈퍼 조종사','지도1 끝 연습','지도2 끝 연습') loop
    st := coalesce(prof.state, '{}'::jsonb);
    st := st || jsonb_build_object(
      'seeon.unlock.cdots', 5,
      'seeon.stars.cdots.1', 3, 'seeon.stars.cdots.2', 3, 'seeon.stars.cdots.3', 3, 'seeon.stars.cdots.4', 3, 'seeon.stars.cdots.5', 3);
    update public.seeon_profiles set state = st, updated_at = now() where id = prof.id;
    n := n + 1;
    if prof.nickname = '슈퍼 조종사' then
      insert into public.seeon_records (profile_id, user_id, cid, game_key, game_name, stage, stars, dur, xp, m, metrics, played_at)
      select prof.id, prof.user_id, 'super-cdots-' || s, 'cdots', 'RAINBOW CLUSTER', s, 3, 40 + s * 2, 40,
             '{"acc":1,"rt":900,"late":0,"rg":1,"by":1,"ctl":1}'::jsonb, '{}'::jsonb,
             ((day0 - s)::timestamp + make_interval(hours => 16, mins => 10 * s)) at time zone 'Asia/Seoul'
      from generate_series(1, 5) as s
      on conflict (profile_id, cid) do nothing;
    end if;
  end loop;
  raise notice '무지개 별무리 보정 완료: 조종사 %명', n;
end $$;
