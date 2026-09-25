# SeeON 웹 게임 연결 가이드 (한 번만 하면 됩니다)

최종 주소는 **https://seeon.equald.kr** 입니다.

| 역할 | 서비스 | 비용 |
|---|---|---|
| 게임 페이지 호스팅 | GitHub Pages (이 저장소) | 무료 |
| 로그인(카카오·구글) + 기록 DB | Supabase | 무료 플랜 |
| 주소 | equald.kr 도메인의 하위 주소 `seeon` | 기존 도메인 |

이후 게임 수정은 Claude가 이 저장소를 고쳐 올리면 1~2분 뒤 자동으로 반영됩니다.

> 🔐 **비밀번호, Client Secret, 인증코드는 채팅에 붙여넣지 말고 각 사이트에 직접 입력해 주세요.**
> 예외는 Supabase의 **Project URL**과 **anon public key**입니다. 이 두 값은 원래 웹페이지에 공개되는 값이라 Claude에게 알려주셔도 됩니다.

---

## 1단계 — GitHub 저장소
1. github.com → 오른쪽 위 **＋ → New repository**
2. Repository name: `seeon-play`, **Public**으로 둡니다. GitHub Pages 무료 플랜은 공개 저장소만 지원합니다. 어차피 게임 코드는 브라우저에서 누구나 볼 수 있는 파일이라 공개해도 문제없습니다.
3. "Add a README" 같은 옵션은 **체크하지 않은 빈 저장소**로 만들고, 주소(`https://github.com/<아이디>/seeon-play`)를 Claude에게 알려주세요.
4. Claude가 이 저장소에 올릴 수 있도록 권한을 연결합니다. 방법은 Claude가 채팅에서 안내합니다.

## 2단계 — Supabase (로그인 + DB)
1. supabase.com → **Start your project** → GitHub 계정으로 가입
2. **New project**
   - Name: `seeon`
   - Database Password: 자동 생성된 값을 그대로 두고 따로 보관합니다.
   - Region: **Northeast Asia (Seoul)**
3. 프로젝트가 만들어지면 왼쪽 **SQL Editor → New query**를 엽니다. 이 저장소의 `supabase/schema.sql` 내용을 전부 붙여넣고 **Run**을 누릅니다. "Success"가 나오면 됩니다.
4. **Project Settings → API**에서 **Project URL**과 **anon public** 키를 복사해 Claude에게 알려주세요. Claude가 `config.js`에 넣어 올립니다.
5. **Authentication → URL Configuration**
   - Site URL: `https://seeon.equald.kr`
   - Redirect URLs에 두 개를 추가합니다: `https://seeon.equald.kr/**`, `https://<GitHub아이디>.github.io/seeon-play/**`(도메인 연결 전 테스트용)

> 무료 플랜은 7일 동안 아무도 접속하지 않으면 프로젝트가 일시정지됩니다. 대시보드에서 **Restore**를 누르면 기록 그대로 다시 켜집니다.

## 3단계 — 카카오 로그인
1. developers.kakao.com → 로그인 → **내 애플리케이션 → 애플리케이션 추가**(앱 이름 `SeeON`, 회사명 `EqualD`)
2. **앱 설정 → 앱 → 일반 → 비즈니스 → "개인 개발자 비즈 앱" 등록**
   - Supabase는 카카오에 이메일 권한을 항상 함께 요청합니다. 그래서 이메일 동의항목을 켜려면 이 등록이 꼭 필요합니다. 사업자번호 없이 개인으로 등록할 수 있습니다.
3. **카카오 로그인 → 활성화 ON**
4. **Redirect URI**: `https://<Supabase 프로젝트 ref>.supabase.co/auth/v1/callback`
   - Supabase의 Authentication → Providers → Kakao 화면에 **Callback URL**로 표시되는 값을 그대로 복사하면 됩니다.
5. **동의항목**
   - 닉네임: 필수
   - 프로필 사진: 선택
   - 카카오계정(이메일): 선택
6. **보안 → Client Secret** 코드 생성 → 활성화
7. Supabase → **Authentication → Providers → Kakao** → Enable을 켜고, 다음 두 값을 **직접 붙여넣은 뒤** Save합니다.
   - REST API 키 → Client ID
   - Client Secret → Secret

## 4단계 — 구글 로그인
1. console.cloud.google.com → 새 프로젝트 `SeeON`
2. **APIs & Services → OAuth consent screen**(Google Auth Platform)
   - 사용자 유형: External
   - 앱 이름: `SeeON`
   - 지원 이메일 입력 후 저장 → **Publish app(프로덕션)**
3. **Credentials → Create credentials → OAuth client ID → Web application**
   - Authorized JavaScript origins: `https://seeon.equald.kr`
   - Authorized redirect URIs: 위 카카오 단계와 같은 Supabase Callback URL
4. 발급된 Client ID와 Client Secret을 Supabase → **Authentication → Providers → Google**에 **직접 붙여넣고** Save합니다.

## 5단계 — 주소 연결 (seeon.equald.kr)
1. GitHub 저장소 → **Settings → Pages**
   - Source: *Deploy from a branch*
   - Branch: `main`, 폴더: `/ (root)` → Save
   - 먼저 `https://kytae.github.io/seeon-play/` 에서 게임이 뜨는지 확인한 뒤, 아래 DNS 레코드를 추가하고 나서 Custom domain에 `seeon.equald.kr` 입력 → Save
2. equald.kr 도메인을 **관리하는 곳**(도메인을 산 곳: 가비아·후이즈·Cloudflare 등)의 DNS 설정에 레코드 하나를 추가합니다.

   | 타입 | 이름(호스트) | 값 |
   |---|---|---|
   | CNAME | `seeon` | `<GitHub아이디>.github.io` |

   도메인을 Manus에서 샀거나 네임서버가 Manus로 되어 있다면, Manus의 도메인/DNS 설정 화면에서 추가합니다. 이 작업은 사이트 코드와는 관계가 없습니다.
3. 10분~몇 시간 뒤 Pages 화면에 초록색 체크가 뜨면 **Enforce HTTPS**를 켭니다.

## 6단계 — 이퀄디 홈페이지에서 연결
이퀄디 관리자 페이지 → 슬라이드(또는 SeeON 버튼)의 **링크** 칸에 `https://seeon.equald.kr`를 입력합니다.

## 확인
- [ ] https://seeon.equald.kr 에서 게임이 열린다
- [ ] 조종사 만들기 화면에 카카오와 구글 버튼이 보인다
- [ ] 카카오로 로그인하면 게임으로 돌아오고, 오른쪽 위에 ☁️ 표시가 생긴다
- [ ] 한 판 한 뒤 휴대폰에서 같은 계정으로 로그인하면 기록이 보인다
