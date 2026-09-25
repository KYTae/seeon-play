#!/usr/bin/env node
/**
 * src/game.html(게임 본문) → index.html(배포용 완성 페이지)
 *   node tools/build.mjs
 * - 완전한 HTML 문서로 감싸고 config.js / vendor/supabase.js 를 먼저 불러옵니다.
 * - three.js 는 CDN 대신 같은 사이트(vendor/three.min.js)에서 먼저 불러옵니다.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
let html = readFileSync(resolve(root, "src/game.html"), "utf8");

const CDN_TAG = '<script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/0.128.0/three.min.js"></script>';
html = html.replace(CDN_TAG, "");
const URLS = 'var THREE_URLS=["https://cdnjs.cloudflare.com/ajax/libs/three.js/0.128.0/three.min.js",';
if (!html.includes(URLS)) throw new Error("THREE_URLS 를 찾지 못했습니다");
html = html.replace(URLS, 'var THREE_URLS=["vendor/three.min.js","https://cdnjs.cloudflare.com/ajax/libs/three.js/0.128.0/three.min.js",');
html = html.replace(/^\s*<title>[^<]*<\/title>/, "");

const head = `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#7A24F5">
<meta name="description" content="SeeON 우주 눈 훈련 — 게임으로 즐기는 어린이 눈 운동 (EqualD)">
<meta property="og:title" content="SeeON 우주 눈 훈련 | EqualD">
<meta property="og:description" content="게임으로 즐기는 어린이 눈 운동. 로그인하면 기록이 계정에 저장되고 보호자 리포트로 확인할 수 있어요.">
<meta property="og:url" content="https://seeon.equald.kr/">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<title>SeeON 우주 눈 훈련 | EqualD</title>
<script src="config.js"></script>
<script src="vendor/supabase.js"></script>
</head>
<body>
`;
writeFileSync(resolve(root, "index.html"), head + html + "\n</body>\n</html>\n");
console.log("✓ index.html");
