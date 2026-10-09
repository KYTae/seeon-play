# SeeON 자체 회원가입 설정 가이드

카카오·구글 대신 **이메일 + 비밀번호**로 보호자(만 14세 이상)가 직접 가입합니다. 가입하면 기록이 계정에 저장되고 **보호자 리포트**를 볼 수 있습니다.

## 가입 흐름
1. 이메일 입력 → [중복 확인]. 이미 가입된 이메일이면 로그인이나 비밀번호 찾기로 안내합니다.
2. 비밀번호 입력: 8~64자, 영문과 숫자를 모두 포함하고 공백은 쓸 수 없습니다. 강도 막대가 보이고, 비밀번호 확인 칸에 같은 값을 다시 입력합니다.
3. 보호자 호칭(선택)을 입력합니다.
4. 동의 항목을 체크합니다. **필수** 4개와 **선택** 1개로 나뉘며, 전체 동의 버튼과 항목마다 [보기]가 있습니다.
   - (필수) 만 14세 이상입니다
   - (필수) 이용약관 동의
   - (필수) 개인정보 수집·이용 동의: 목적·항목·보유기간, 동의 거부권과 거부 시 불이익을 안내합니다.
   - (필수) 만 14세 미만 자녀 개인정보 처리에 대한 법정대리인 동의
   - (선택) 광고성 정보 수신 동의(이메일): 체크하지 않은 상태가 기본이며, 필수 동의와 분리돼 있습니다.
5. 가입하면 인증 메일이 발송됩니다. 메일의 버튼을 누르면 가입과 **법정대리인 동의 확인**이 함께 완료됩니다.
6. 로그인하면 동의 기록이 서버의 `seeon_consents`에 동의 항목·버전·일시로 저장되고, 체험 모드에서 쌓은 기록은 계정으로 합쳐집니다.

## 계정 화면에서 할 수 있는 일 (정보주체 권리)
- 광고성 정보 수신 동의·철회: 처리하면 날짜와 처리 결과를 바로 보여 줍니다.
- 비밀번호 변경: 지금 비밀번호를 한 번 더 확인한 뒤 바꿉니다.
- **내 데이터 내려받기**(JSON): 조종사, 게임 기록, 동의 기록을 받습니다.
- **회원 탈퇴**: 비밀번호를 확인하고 "탈퇴"를 입력하면 계정, 조종사, 기록, 동의 기록이 즉시 삭제됩니다.
- 약관과 개인정보 처리방침 보기

## 보안
- 비밀번호는 Supabase Auth가 bcrypt로 암호화해 저장합니다. 회사도 원래 비밀번호를 볼 수 없습니다.
- 모든 통신은 HTTPS로 이뤄집니다.
- 모든 테이블에 행 수준 보안(RLS)을 적용해, 로그인한 계정은 자기 데이터만 읽고 쓸 수 있습니다.
- 동의 기록 쓰기, 탈퇴, 관리자 기능은 서버 함수로만 동작하고, 함수 안에서 권한을 확인합니다.
- 인증 링크와 비밀번호 재설정 링크는 1회용이며 시간이 지나면 만료됩니다. 로그인과 메일 발송에는 Supabase 기본 속도 제한이 걸립니다.

---

## 설정 순서 (한 번만)

### 1. SQL 실행
Supabase → SQL Editor에 `supabase/members.sql` 전체를 붙여넣고 **Run**합니다.

### 2. 이메일 로그인 설정
Supabase → **Authentication → Sign In / Providers → Email**
- Enable Email provider: **ON**
- **Confirm email: ON** (필수 — 법정대리인 동의 확인과 이메일 도용 방지)
- Secure email change: ON
- Minimum password length: **8**
- Password requirements: **Letters and digits**
- Save

### 3. 메일 발송 서버(SMTP) 연결 — 꼭 필요
Supabase 기본 메일 서버는 **프로젝트 팀원 이메일에만** 보내고 시간당 2통으로 제한됩니다. 실제 회원에게 인증·비밀번호 재설정 메일을 보내려면 메일 발송 서비스를 연결해야 합니다.

**추천: Resend (무료 월 3,000통)**
1. resend.com에 가입한 뒤 Domains → Add Domain에서 `equald.kr`을 추가합니다.
2. 화면에 나오는 DNS 레코드(TXT/MX)를 **가비아 DNS 관리**에 그대로 추가합니다. seeon CNAME을 넣었던 그 화면입니다. 인증되면 초록색으로 바뀝니다.
3. API Keys → Create API Key로 키를 만들어 복사합니다.
4. Supabase → **Authentication → Emails → SMTP Settings** → Enable Custom SMTP
   - Sender email: `no-reply@equald.kr`
   - Sender name: `SeeON`
   - Host: `smtp.resend.com`
   - Port: `465`
   - Username: `resend`
   - Password: 3번에서 복사한 API 키
5. Save

> 연결하면 `legal.html` 개인정보 처리방침 5번 표의 【메일 발송 업체】 칸에 `Resend, Inc. · 미국`을 적어 주세요.

### 4. 메일 템플릿 (한국어)
Supabase → **Authentication → Emails → Templates**. 각 템플릿의 제목과 본문을 아래 내용으로 바꿉니다. 링크가 `token_hash` 방식이라 **메일을 다른 기기나 앱에서 열어도** 인증이 됩니다.

**Confirm signup**
- 제목: `[SeeON] 이메일 인증을 완료해 주세요`
```html
<div style="font-family:sans-serif;max-width:480px;margin:auto;padding:24px;color:#1b1726">
  <h2 style="color:#6d28d9">SeeON 우주 눈 훈련</h2>
  <p>안녕하세요! SeeON 보호자 회원가입을 요청하셨어요.</p>
  <p>아래 버튼을 누르면 <b>이메일 인증</b>과 함께, 가입 화면에서 동의하신 <b>만 14세 미만 자녀 개인정보 처리에 대한 법정대리인 동의</b>가 확인되어 가입이 완료됩니다.</p>
  <p style="margin:28px 0"><a href="{{ .SiteURL }}/?token_hash={{ .TokenHash }}&type=signup" style="background:#7a24f5;color:#fff;padding:14px 26px;border-radius:999px;text-decoration:none;font-weight:bold">이메일 인증하기</a></p>
  <p style="color:#8b8698;font-size:13px">본인이 요청하지 않았다면 이 메일을 무시해 주세요. 인증하지 않으면 가입되지 않습니다.<br>운영: 이퀄디(EqualD) · jafeel@equald.biz</p>
</div>
```

**Reset password**
- 제목: `[SeeON] 비밀번호 재설정 안내`
```html
<div style="font-family:sans-serif;max-width:480px;margin:auto;padding:24px;color:#1b1726">
  <h2 style="color:#6d28d9">SeeON 비밀번호 재설정</h2>
  <p>아래 버튼을 누르면 새 비밀번호를 만들 수 있어요.</p>
  <p style="margin:28px 0"><a href="{{ .SiteURL }}/?token_hash={{ .TokenHash }}&type=recovery" style="background:#7a24f5;color:#fff;padding:14px 26px;border-radius:999px;text-decoration:none;font-weight:bold">새 비밀번호 만들기</a></p>
  <p style="color:#8b8698;font-size:13px">본인이 요청하지 않았다면 이 메일을 무시해 주세요. 비밀번호는 바뀌지 않습니다.<br>운영: 이퀄디(EqualD) · jafeel@equald.biz</p>
</div>
```

**Change email address**
- 제목: `[SeeON] 이메일 변경 확인`
- 링크: `{{ .SiteURL }}/?token_hash={{ .TokenHash }}&type=email_change`

### 5. URL 설정 확인
Authentication → URL Configuration의 **Site URL**이 `https://seeon.equald.kr`인지 확인합니다. 메일 링크의 `{{ .SiteURL }}`에 이 주소가 들어갑니다.

### 6. 법적 문서 빈칸 채우기 (`legal.html`)
(완료) 아래 칸은 2026-09-25에 채웠습니다: 사업자등록번호 323-88-03311, 대표자·개인정보 보호책임자 정재필(CEO), 메일 발송 업체 Plus Five Five, Inc.(Resend).
- 이용약관 하단: 사업자등록번호, 대표자
- 개인정보 처리방침 5번: 메일 발송 업체(3번에서 연결한 곳)
- 개인정보 처리방침 10번: 개인정보 보호책임자 성명과 직책

> ⚖️ 문서는 「개인정보 보호법」 제22조(동의 방법)·제22조의2(아동)·제28조의8(국외 이전)·제30조(처리방침), 「정보통신망법」 제50조(광고성 정보)를 반영해 작성했습니다. 다만 법률 자문을 대신하지는 않으므로, **정식 판매 전에는 법률 전문가의 검토를 받으시길 권합니다.**

---

## 운영하면서 지켜야 할 것 (광고성 정보)
- 광고 메일은 관리자 페이지 **관리자 설정 → 광고성 정보 수신 동의자** 목록에 있는 사람에게만 보냅니다(CSV 내려받기 가능).
- 광고 메일 제목에는 `(광고)`를 붙이고, 본문에 보내는 곳과 **수신거부 방법**을 적습니다.
- 동의한 날로부터 **2년마다** 수신 동의 여부를 다시 확인하는 메일을 보냅니다. 목록의 "2년 재확인 필요" 칸을 참고하세요.
- 회원이 동의하거나 철회하면 화면에 처리 결과가 바로 표시됩니다.
