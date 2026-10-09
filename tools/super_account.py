# 슈퍼 계정 SQL 만들기 — 비밀번호는 실행할 때 새로 만들어 이 파일에 넣지 않아요 (저장소에 올리지 않음)
import json, random, secrets, string, sys, time
random.seed(20260926)
EMAIL = sys.argv[1] if len(sys.argv)>1 else 'super@equald.kr'
PW = sys.argv[2] if len(sys.argv)>2 else None
OUT = sys.argv[3] if len(sys.argv)>3 else 'super_account.sql'
if not PW:
    a=string.ascii_letters+string.digits
    while True:
        PW='Seeon-'+''.join(secrets.choice(a) for _ in range(10))
        if any(c.isdigit() for c in PW[6:]) and any(c.isalpha() for c in PW[6:]): break
NOW = int(time.time()*1000); DAY=86400000
STAGED=[("meteor",5),("stellar",7),("starcode.0",5),("starcode.1",5),("twin",5),("radar",5),("comet",7),("numorbit",5),("count",7),("guard",5),("mot",5),("faint",5),("search",5),("nova",5)]
# 단계 구성이 바뀐 게임: 별·해금은 새 칸에 저장, 기록에는 새 번호 표시(mk)
NK={"meteor":("meteor5","s5"),"comet":("comet5","s5"),"numorbit":("numorbit5","s5"),"guard":("guard5","s5"),"faint":("faint5","s5"),"nova":("nova2","s2"),"search":("search2","s2"),"count":("count2","s2")}
def sk(k): return NK[k][0] if k in NK else k
def base_state(nick, ava, lv, story_n, m2=False, m3=False):
    st={"seeon.profile":{"nick":nick,"ava":ava,"lv":lv,"xp":0}}
    for k,mx in STAGED:
        st["seeon.unlock."+sk(k)]=mx
        for s in range(1,mx+1): st[f"seeon.stars.{sk(k)}.{s}"]=3
    sto={"seed":7,"st":{}}
    for i in range(1,story_n+1): sto["st"][str(i)]={"s":3,"at":NOW-(story_n-i+1)*3600000}
    if m2: sto["m2"]=1
    if m3: sto["m3"]=1
    st["seeon.story"]=sto
    st["seeon.breaks"]=[{"at":NOW-d*DAY-5*3600000,"ok":True} for d in range(1,13)]
    return st
super_state=base_state("슈퍼 조종사",1,50,150,True,True)
# 시력 측정 기록 몇 개 (그래프·비교 보기용)
vis=[]; 
for n,(d,r,l) in enumerate([(20,.6,.6),(13,.7,.6),(6,.7,.7),(1,.8,.7)]):
    vis.append({"at":NOW-d*DAY-3*3600000,"r":r,"l":l,"d":1000,"cap":1.5,"mode":"btn","approx":False,"ok":14,"n":18,"ipd":55,"cover":"ok"})
super_state["seeon.vision"]={"v":1,"list":vis}
pilots=[
  {"nick":"슈퍼 조종사","ava":1,"lv":50,"state":super_state},
  {"nick":"지도1 끝 연습","ava":3,"lv":12,"state":base_state("지도1 끝 연습",3,12,49)},
  {"nick":"지도2 끝 연습","ava":2,"lv":25,"state":base_state("지도2 끝 연습",2,25,99,True)},
]
# 게임 기록: 36일 연속 × 하루 9판 (18종 모두 · 별 3개 · 눈 측정 기록 포함)
KINDS=[("meteor","METEOR SMASH",5,{"rt":420}),("stellar","STELLAR LINK",7,{"digits":7}),("starcode.0","STAR CODE",5,{"acc":.95}),("starcode.1","STAR CODE",5,{"acc":.92}),
 ("twin","TWIN PLANETS",5,{"reach":.93}),("radar","GALAXY RADAR",5,{"acc":.9}),("comet","COMET SCAN",7,{"acc":.9}),("numorbit","NUMBER ORBIT",5,{"time":24}),
 ("count","STAR COUNT",7,{"acc":.93}),("nova","COLOR NOVA",5,{"acc":.93,"rt":820}),("guard","REFLEX GUARD",5,{"acc":.94}),("mot","SPY TRACK",5,{"acc":.9}),
 ("faint","FAINT STAR",5,{"thr":6}),("search","HIDDEN ALIEN",5,{"time":1.3}),("orbit","ORBIT SPIN",0,{}),("luna","LUNA SWING",0,{}),("astro","ASTRO LINE",0,{}),
 ("compass","COSMIC COMPASS",0,{}),("story","STAR STORY",0,{})]
EYE={"luna","astro","compass","twin","stellar"}
recs=[]; k=0
for d in range(36,0,-1):
    for j in range(9):
        key,game,mx,m=KINDS[k%len(KINDS)]; k+=1
        m=dict(m)
        if key in NK: m[NK[key][1]]=1   # 새 단계 번호로 남긴 기록
        if key in EYE and random.random()<.6: m.update({"e_q":round(random.uniform(.72,.92),3),"e_fv":.95,"e_hs":.9,"e_bl":14,"e_n":300})
        free=mx==0
        stars=None if free else 3
        rec={"d":d,"min":10*60+j*55+random.randint(0,20),"key":key,"game":game,"stage":(None if free else random.randint(1,mx)),"stars":stars,
             "dur":(random.randint(150,300) if free else random.randint(80,160)),"xp":(20 if free else 40),"m":m,"metrics":{}}
        recs.append(rec)
esc=lambda s: s.replace("'","''")
sql=f"""-- ═══════════════════════════════════════════════════════════════════
--  SeeON 슈퍼 계정 (테스트·시연용) — Supabase SQL Editor 에서 한 번 실행
--  ⚠️ 비밀번호가 들어 있어요. GitHub 저장소에 올리지 말고, 실행한 뒤에는 지워 주세요.
--  여러 번 실행해도 돼요: 같은 이메일이면 비밀번호·조종사·기록을 처음 상태로 다시 만들어요.
--  먼저 schema.sql · admin.sql · members.sql · eye.sql 을 실행해 둔 상태여야 해요.
--
--  조종사 3명:
--   1) 슈퍼 조종사   — 우주 모험 150 행성 모두 별 3개 · 모든 게임 모든 단계 열림·별 3개(게임 별 186) · 레벨 50 · 배지 38개 모두
--   2) 지도1 끝 연습 — 49번째 행성까지 깬 상태 → 50번째를 깨면 지도 1→2 넘어가는 연출을 실제로 볼 수 있어요
--   3) 지도2 끝 연습 — 99번째 행성까지 깬 상태 → 100번째를 깨면 지도 2→3 넘어가는 연출
-- ═══════════════════════════════════════════════════════════════════
do $$
declare
  v_email text := '{esc(EMAIL)}';
  v_pw    text := '{esc(PW)}';
  uid uuid; pid bigint; p jsonb; r jsonb; i int := 0;
  v_pilots jsonb := '{esc(json.dumps(pilots,ensure_ascii=False))}'::jsonb;
  v_recs   jsonb := '{esc(json.dumps(recs,ensure_ascii=False))}'::jsonb;
  v_day0 date := (now() at time zone 'Asia/Seoul')::date;
begin
  -- ① 로그인 계정 (이메일 인증까지 끝난 상태로)
  select id into uid from auth.users where lower(email) = lower(v_email);
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', lower(v_email),
            extensions.crypt(v_pw, extensions.gen_salt('bf')), now(),
            '{{"provider":"email","providers":["email"]}}'::jsonb,
            jsonb_build_object('name','슈퍼 계정','consent',jsonb_build_object('v','2026-09-25','terms',true,'privacy',true,'age14',true,'guardian',true,'marketing',false)),
            now(), now(), '', '', '', '');
    insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', lower(v_email), 'email_verified', true), 'email', now(), now(), now());
  else
    update auth.users set encrypted_password = extensions.crypt(v_pw, extensions.gen_salt('bf')),
                          email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
    where id = uid;
  end if;
  -- 도서 쿠폰 없이 전체 이용 (coupons.sql 을 실행한 서버에서만)
  if to_regclass('public.seeon_entitlements') is not null then
    execute 'insert into public.seeon_entitlements (user_id, source) values ($1, ''legacy'') on conflict (user_id) do nothing' using uid;
  end if;

  -- ② 동의 기록 (필수 + 눈 측정·시력 기록 저장 동의)
  delete from public.seeon_consents where user_id = uid;
  insert into public.seeon_consents (user_id, kind, agreed, version) values
    (uid,'terms',true,'2026-09-25'),(uid,'privacy',true,'2026-09-25'),(uid,'age14',true,'2026-09-25'),
    (uid,'guardian',true,'2026-09-25'),(uid,'marketing_email',false,'2026-09-25'),
    (uid,'eye_metrics',true,'2026-09-25'),(uid,'vision_results',true,'2026-09-25');

  -- ③ 조종사 (예전 조종사·기록은 지우고 새로)
  delete from public.seeon_profiles where user_id = uid;
  for p in select * from jsonb_array_elements(v_pilots) loop
    i := i + 1;
    insert into public.seeon_profiles (user_id, nickname, avatar, level, xp, state, created_at)
    values (uid, p->>'nick', (p->>'ava')::int, (p->>'lv')::int, 0, p->'state', now() - make_interval(secs => 10 - i))
    returning id into pid;
    -- ④ 게임 기록은 슈퍼 조종사만: 어제까지 36일 연속, 하루 9판
    if i = 1 then
      insert into public.seeon_records (profile_id, user_id, cid, game_key, game_name, stage, stars, dur, xp, m, metrics, played_at)
      select pid, uid, 'super-' || lpad(n::text, 4, '0'), x->>'key', x->>'game',
             nullif(x->>'stage','')::int, nullif(x->>'stars','')::int, (x->>'dur')::int, (x->>'xp')::int, x->'m', x->'metrics',
             ((v_day0 - (x->>'d')::int)::timestamp + make_interval(mins => (x->>'min')::int)) at time zone 'Asia/Seoul'
      from jsonb_array_elements(v_recs) with ordinality as t(x, n);
    end if;
  end loop;
  raise notice '슈퍼 계정 준비 완료: % (조종사 3명, 기록 %판)', v_email, jsonb_array_length(v_recs);
end $$;
"""
open(OUT,'w').write(sql)

print(EMAIL); print(PW); print(len(recs),"records")
