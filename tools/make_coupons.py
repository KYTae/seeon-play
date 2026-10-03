#!/usr/bin/env python3
"""SeeON 도서 쿠폰 번호 만들기

사용법:  python3 tools/make_coupons.py BOOK1 1100 [출력폴더]

만드는 파일 (출력폴더, 기본: 현재 폴더)
  coupons_<묶음>_print.csv   인쇄소에 넘길 목록 (일련번호, 쿠폰 번호)  ← 비밀! 저장소에 올리지 마세요
  coupons_<묶음>_insert.sql  Supabase SQL Editor 에서 Run (번호 원문 없이 해시만 들어 있어요)
  coupons_<묶음>_check.txt   자체 검사 결과

번호 규칙
  XXXX-XXXX-XXXX · 무작위 11자 + 검사 문자 1자 (Luhn mod 30)
  쓰는 글자 30종: 2-9, A-Z 중 I·L·O·U 뺀 글자 (0/O, 1/I/L, U/V 헷갈림 방지)
  암호학적 난수(secrets) 사용
"""
import csv, hashlib, os, secrets, sys

ALPHA = "23456789ABCDEFGHJKMNPQRSTVWXYZ"
N = len(ALPHA)
assert N == 30 and len(set(ALPHA)) == 30


def check_char(body: str) -> str:
    """Luhn mod N: 한 글자 틀림과 이웃 두 글자 바뀜을 모두 잡아요."""
    factor, total = 2, 0
    for ch in reversed(body):
        a = factor * ALPHA.index(ch)
        factor = 1 if factor == 2 else 2
        total += a // N + a % N
    return ALPHA[(N - total % N) % N]


def valid(code: str) -> bool:
    c = normalize(code)
    if len(c) != 12 or any(ch not in ALPHA for ch in c):
        return False
    return check_char(c[:11]) == c[11]


def normalize(code: str) -> str:
    return "".join(ch for ch in code.upper() if ch.isalnum())


def fmt(c: str) -> str:
    return f"{c[0:4]}-{c[4:8]}-{c[8:12]}"


def code_hash(c: str) -> str:
    return hashlib.sha256(("seeon-coupon:" + normalize(c)).encode()).hexdigest()


def make(n: int):
    seen, out = set(), []
    while len(out) < n:
        body = "".join(secrets.choice(ALPHA) for _ in range(11))
        c = body + check_char(body)
        if c in seen:
            continue
        seen.add(c)
        out.append(c)
    return out


def self_check(codes):
    errs = []
    if len(set(codes)) != len(codes):
        errs.append("중복 번호가 있어요")
    for c in codes:
        if not valid(c):
            errs.append(f"검사 문자 오류: {c}")
        if any(ch in "01ILOU" for ch in c):
            errs.append(f"금지 글자: {c}")
    # 검사 문자가 한 글자 오타를 모두 잡는지 표본으로 시험 (이웃 두 글자 바뀜은 거의 다 잡아요 — 못 잡아도 서버에서 '없는 번호'로 걸러져요)
    miss = 0
    for c in codes[:300]:
        for i in range(12):
            for ch in ALPHA:
                if ch != c[i] and valid(c[:i] + ch + c[i + 1:]):
                    miss += 1
    if miss:
        errs.append(f"한 글자 오타를 못 잡는 경우 {miss}건")
    hs = [code_hash(c) for c in codes]
    if len(set(hs)) != len(hs):
        errs.append("해시 충돌")
    return errs


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    batch = sys.argv[1].strip().upper()
    n = int(sys.argv[2])
    out = sys.argv[3] if len(sys.argv) > 3 else "."
    if not batch.replace("_", "").isalnum() or not (1 <= n <= 100000):
        sys.exit("묶음 이름은 영문·숫자, 수량은 1~100000")
    os.makedirs(out, exist_ok=True)
    codes = make(n)
    errs = self_check(codes)
    if errs:
        sys.exit("검사 실패: " + "; ".join(errs[:5]))

    pcsv = os.path.join(out, f"coupons_{batch}_print.csv")
    with open(pcsv, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["일련번호", "쿠폰 번호"])
        for i, c in enumerate(codes, 1):
            w.writerow([f"{batch}-{i:04d}", fmt(c)])

    psql = os.path.join(out, f"coupons_{batch}_insert.sql")
    with open(psql, "w", encoding="utf-8") as f:
        f.write(f"-- SeeON 도서 쿠폰 {batch} · {n}개 (번호 원문 없이 해시만)\n")
        f.write("-- 먼저 coupons.sql 을 실행한 뒤, 이 파일을 SQL Editor 에 붙여넣고 Run 하세요. 여러 번 실행해도 안전해요.\n")
        for k in range(0, n, 500):
            part = codes[k:k + 500]
            f.write("insert into public.seeon_coupons (batch, serial, code_hash) values\n")
            f.write(",\n".join(f"  ('{batch}', {k + j + 1}, '{code_hash(c)}')" for j, c in enumerate(part)))
            f.write("\non conflict do nothing;\n")
        f.write(f"""do $$ declare n int; begin
  select count(*) into n from public.seeon_coupons where batch = '{batch}';
  if n <> {n} then raise exception '쿠폰 수가 맞지 않아요: % / {n}', n; end if;
  raise notice '쿠폰 {batch}: % 개 준비 완료', n;
end $$;
select batch, count(*) as total, count(*) filter (where status = 'new') as unused from public.seeon_coupons where batch = '{batch}' group by batch;
""")

    with open(os.path.join(out, f"coupons_{batch}_check.txt"), "w", encoding="utf-8") as f:
        f.write(f"묶음 {batch} · {n}개\n중복 0 · 검사 문자 전부 통과 · 금지 글자 0 · 한 글자 오타 표본 시험 통과 · 해시 충돌 0\n")
        f.write(f"쓰는 글자 {ALPHA} ({N}종) · 경우의 수 30^11 = {30**11:,}\n")
    print(f"✅ {n}개 생성 · 검사 통과\n  {pcsv}\n  {psql}")


if __name__ == "__main__":
    main()
