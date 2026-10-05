#!/usr/bin/env node
// 나무위키 실검을 받아 별도 Git 인덱스로 원격 스냅샷 커밋을 만든다. macOS·Windows 공용.
// 현재 작업 트리의 수정은 커밋에 포함하지 않는다.
// --scheduled는 최근 성공 후 NAMU_MIN_INTERVAL_MIN분 동안 중복 수집을 건너뛴다.
// 수동 실행은 새로 수집하며, 네트워크 요청과 origin/<NAMU_BRANCH> push를 수행한다.
//
// 순위를 받는 길: 2026-10-04 에 search.namu.wiki 가 DNS 에서 사라졌다(NXDOMAIN). 실검은 이제
// namu.wiki 페이지 스크립트가 서명 헤더를 붙여 받고 암호화된 응답을 풀어 카드에 그린다.
// 그 헤더를 흉내 내지 않는다. 헤드리스 Chrome 으로 대문을 그대로 띄우고, 그려진 카드의
// /Go?q= 링크를 읽는다.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WIN = process.platform === 'win32';
const HOME = os.homedir();
const env = process.env;

// 로그·상태는 기기마다 둔다. 윈도우는 AppData 밖이어야 한다(Claude 앱 MSIX 가상화 때문에
// 앱 안에서 돌린 것과 작업 스케줄러가 돌린 것이 서로 다른 파일을 보게 된다).
const STATE_DIR = WIN ? path.join(HOME, '.namu-trending') : path.join(HOME, 'Library', 'Caches');
const LOG = env.NAMU_LOG || (WIN ? path.join(STATE_DIR, 'namu-ranking-snapshot.log')
  : path.join(HOME, 'Library', 'Logs', 'namu-ranking-snapshot.log'));
const TARGET_BRANCH = env.NAMU_BRANCH || 'main';
// 20분인 이유: 슬롯 간격이 가장 좁은 데가 07:00~07:45 로 45분이다. 창을 40분으로 잡으면
// 07:00 슬롯이 밀렸을 때 07:45 가 통째로 건너뛰어진다. RunAtLoad 처럼 슬롯 직후에 또
// 받는 것만 막으면 되므로 넉넉히 작아도 된다.
const MIN_INTERVAL_MIN = Number(env.NAMU_MIN_INTERVAL_MIN || 20);
const STATE = env.NAMU_STATE || path.join(STATE_DIR, 'me.1hyok.namu-ranking-snapshot.last');
// 락 경로는 고정한다. TMPDIR 은 실행 경로마다 달라질 수 있어 그 위에 두면 손으로 돌린 것과
// 예약 실행이 서로를 못 본다.
const LOCK = path.join(STATE_DIR, 'me.1hyok.namu-ranking-snapshot.lock');
const NET_TIMEOUT = Number(env.NAMU_NET_TIMEOUT || 60);
const PAGE_TIMEOUT = Number(env.NAMU_PAGE_TIMEOUT || 45);
const SNAP = 'ranking-latest.json';
const PAGE = 'https://namu.wiki/w/%EB%82%98%EB%AC%B4%EC%9C%84%ED%82%A4:%EB%8C%80%EB%AC%B8';
const SOURCE = 'https://namu.wiki/ (실시간 검색어 카드)';

const mode = process.argv.includes('--scheduled') ? 'scheduled' : 'manual';
const sleep = ms => new Promise(r => setTimeout(r, ms));

function ts() {
  return new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 19) + '+09:00';
}

fs.mkdirSync(path.dirname(LOG), { recursive: true });
fs.mkdirSync(STATE_DIR, { recursive: true });
// 로그가 무한정 자라지 않게 500KB 넘으면 마지막 2000줄만 남긴다. 자리에서 덮어쓴다.
// 파일을 갈아끼우면 launchd 가 이미 열어 둔 stdout/stderr 가 사라진 inode 를 붙든다.
try {
  if (fs.statSync(LOG).size > 512000) {
    const lines = fs.readFileSync(LOG, 'utf8').split('\n');
    fs.writeFileSync(LOG, lines.slice(-2001).join('\n'));
  }
} catch {}

const log = msg => fs.appendFileSync(LOG, `${ts()} ${msg}\n`);

let haveLock = false;
let resultWritten = false;
function emit(msg) {
  if (resultWritten) return;
  resultWritten = true;
  log(`RESULT ${msg}`);
  if (process.stdout.isTTY) console.log(`RESULT ${msg}`);
}
function finish(code) {
  emit(`fail stage=aborted mode=${mode}`);   // 여기까지 왔으면 위에서 RESULT 를 못 쓰고 끝난 것이다
  if (haveLock) fs.rmSync(LOCK, { recursive: true, force: true });
  process.exit(code);
}
process.on('SIGTERM', () => finish(143));
process.on('SIGINT', () => finish(130));
process.on('uncaughtException', e => { log(`ERROR ${e && e.stack || e}`); finish(1); });
process.on('unhandledRejection', e => { log(`ERROR ${e && e.stack || e}`); finish(1); });

// git 은 자격증명이 없으면 묻지 말고 바로 실패해야 한다. 예약 실행에서 멈추면 아무도 모른다.
const gitEnv = { ...env, GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never' };
if (!WIN) gitEnv.GIT_ASKPASS = '/usr/bin/false';
const GIT = env.NAMU_GIT || 'git';
function git(args, { input, timeout = 30, idx } = {}) {
  const r = spawnSync(GIT, args, {
    cwd: repo, input, encoding: 'utf8', timeout: timeout * 1000, killSignal: 'SIGKILL',
    env: idx ? { ...gitEnv, GIT_INDEX_FILE: idx } : gitEnv,
  });
  if (r.stderr && r.stderr.trim()) fs.appendFileSync(LOG, r.stderr.endsWith('\n') ? r.stderr : r.stderr + '\n');
  if (r.error) fs.appendFileSync(LOG, `git ${args[0]}: ${r.error.message}\n`);
  return { ok: r.status === 0, out: (r.stdout || '').trim() };
}
const gitNet = args => git(['-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=30',
  '-c', 'credential.interactive=false', ...args], { timeout: NET_TIMEOUT });

log(`START mode=${mode} pid=${process.pid}`);

// 슬롯과 RunAtLoad 가 같은 순간에 뜰 수 있어 겹쳐 도는 것을 막는다.
function alive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }
try { fs.mkdirSync(LOCK); haveLock = true; } catch {
  let holder = 0;
  try { holder = Number(fs.readFileSync(path.join(LOCK, 'pid'), 'utf8').trim()) || 0; } catch {}
  if (holder && alive(holder)) { emit(`skip reason=locked holder=${holder} mode=${mode}`); process.exit(0); }
  try { fs.rmSync(LOCK, { recursive: true, force: true }); fs.mkdirSync(LOCK); haveLock = true; } catch {}  // 죽은 락이면 뺏는다
}
if (!haveLock) { emit(`skip reason=lock-unavailable mode=${mode}`); process.exit(0); }
fs.writeFileSync(path.join(LOCK, 'pid'), String(process.pid));

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const checkoutBranch = git(['symbolic-ref', '--quiet', '--short', 'HEAD']).out;

// 신선도는 마지막 성공 시각으로 본다. 작업 트리의 파일은 일부러 안 건드리므로
// 그 파일의 시각은 origin 에 실제로 올라간 것보다 낡아 있을 수 있다.
if (mode === 'scheduled') {
  try {
    const age = Math.floor((Date.now() - fs.statSync(STATE).mtimeMs) / 60000);
    if (age >= 0 && age < MIN_INTERVAL_MIN) { emit(`skip reason=fresh age_min=${age} mode=${mode}`); finish(0); }
  } catch {}
}

function findChrome() {
  if (env.NAMU_CHROME) return env.NAMU_CHROME;
  const c = WIN ? [
    path.join(env.ProgramFiles || 'C:\\Program Files', 'Google\\Chrome\\Application\\chrome.exe'),
    path.join(env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Google\\Chrome\\Application\\chrome.exe'),
    path.join(env.LOCALAPPDATA || '', 'Google\\Chrome\\Application\\chrome.exe'),
    path.join(env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Microsoft\\Edge\\Application\\msedge.exe'),
  ] : [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    path.join(HOME, 'Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),
  ];
  return c.find(p => fs.existsSync(p));
}

// 카드는 순위 1~10 뒤에 무한 회전용으로 1위를 한 번 더 붙인다. 앞에서부터 중복을 걷는다.
const READ_CARD = `JSON.stringify([...document.querySelectorAll('ul')]
  .map(u => [...u.querySelectorAll(':scope > li > a[href^="/Go?q="][title]')].map(a => a.title.trim()))
  .filter(x => x.length >= 5))`;

// 한 번 띄워 읽는다. 성공하면 순위 배열, 아니면 { error } 를 돌려준다.
async function fetchOnce(chromePath) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'namu-cdp-'));
  const ch = spawn(chromePath, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${dir}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--mute-audio',
    '--window-size=1400,900', 'about:blank'], { stdio: 'ignore', windowsHide: true });
  let ws;
  try {
    let port;
    for (let i = 0; i < 200 && !port; i++) {
      await sleep(100);
      try { port = fs.readFileSync(path.join(dir, 'DevToolsActivePort'), 'utf8').split('\n')[0]; } catch {}
    }
    if (!port) return { error: 'chrome-start' };
    const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === 'page');
    ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((ok, no) => { ws.onopen = ok; ws.onerror = () => no(new Error('cdp-connect')); });
    let id = 0; const pend = new Map();
    ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
    const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });

    // 헤드리스 표식만 지운다. 나머지는 이 기기 Chrome 그대로다.
    const ua = (await send('Browser.getVersion')).result.userAgent.replace('HeadlessChrome', 'Chrome');
    await send('Network.setUserAgentOverride', { userAgent: ua, acceptLanguage: 'ko-KR,ko;q=0.9' });
    await send('Page.enable');
    const nav = await send('Page.navigate', { url: PAGE });
    if (nav.result?.errorText) return { error: `navigate:${nav.result.errorText}` };
    const until = Date.now() + PAGE_TIMEOUT * 1000;
    let last = 'empty';
    while (Date.now() < until) {
      await sleep(1000);
      const r = await send('Runtime.evaluate', { expression: READ_CARD, returnByValue: true });
      const lists = JSON.parse(r.result?.result?.value || '[]');
      if (lists.length) {
        const arr = [...new Set(lists[0])];
        if (arr.length >= 5 && arr.every(x => typeof x === 'string' && x)) return arr;
        last = `short:${arr.length}`;
      }
    }
    const t = await send('Runtime.evaluate', { expression: 'document.title', returnByValue: true });
    return { error: `no-card:${last}:${String(t.result?.result?.value || '').slice(0, 40).replace(/\s+/g, '_')}` };
  } catch (e) {
    return { error: `cdp:${e.message}` };
  } finally {
    try { ws && ws.close(); } catch {}
    ch.kill();
    await new Promise(r => { if (ch.exitCode !== null) r(); else { ch.once('exit', r); setTimeout(r, 5000); } });
    if (WIN) spawnSync('taskkill', ['/PID', String(ch.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true });
    try { fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 }); } catch {}
  }
}

const chromePath = findChrome();
if (!chromePath) { emit(`fail stage=fetch reason=no-chrome mode=${mode}`); finish(1); }

// 깨어난 직후엔 네트워크가 아직 안 올라와 있을 수 있어 세 번 시도한다.
let rank = null;
for (let attempt = 1; attempt <= 3; attempt++) {
  const r = await fetchOnce(chromePath);
  if (Array.isArray(r)) { rank = r; break; }
  log(`FETCH attempt=${attempt} ${r.error}`);
  if (attempt < 3) await sleep(10000);
}
if (!rank) { emit(`fail stage=fetch attempts=3 mode=${mode}`); finish(1); }

const now = ts();
log(`RANK ${rank.join(' ')}`);
const payload = JSON.stringify({ fetched_at: now, source: SOURCE, ranking: rank }, null, 2) + '\n';

// origin 위에 스냅샷 커밋 하나를 만들어 그것만 올린다. 그 사이 남이 push 했으면 다시 얹는다.
let pushed = false;
for (let attempt = 1; attempt <= 3 && !pushed; attempt++) {
  if (!gitNet(['fetch', '-q', 'origin', TARGET_BRANCH]).ok) { log(`FETCH-GIT attempt=${attempt} 실패`); continue; }
  const base = git(['rev-parse', 'FETCH_HEAD']);
  if (!base.ok) { log('rev-parse FETCH_HEAD 실패'); continue; }
  const blob = git(['hash-object', '-w', '--stdin'], { input: payload });
  if (!blob.ok) { log('hash-object 실패'); continue; }
  const idx = path.join(os.tmpdir(), `namu-ranking-idx-${process.pid}-${attempt}`);
  try {
    if (!git(['read-tree', base.out], { idx }).ok) { log('read-tree 실패'); continue; }
    if (!git(['update-index', '--add', '--cacheinfo', `100644,${blob.out},${SNAP}`], { idx }).ok) { log('update-index 실패'); continue; }
    const tree = git(['write-tree'], { idx });
    if (!tree.ok) { log('write-tree 실패'); continue; }
    const commit = git(['commit-tree', tree.out, '-p', base.out, '-m', `chore: 나무위키 실검 스냅샷 ${now}`]);
    if (!commit.ok) { log('commit-tree 실패 (git 사용자 설정 확인)'); continue; }
    if (gitNet(['push', '-q', 'origin', `${commit.out}:refs/heads/${TARGET_BRANCH}`]).ok) {
      pushed = true;
      log(`PUSH ok base=${base.out.slice(0, 7)} commit=${commit.out.slice(0, 7)} attempt=${attempt}`);
    } else {
      log(`PUSH attempt=${attempt} 거절 - origin 이 움직였다. 다시 얹는다`);
    }
  } finally {
    fs.rmSync(idx, { force: true });
  }
}
if (!pushed) {
  emit(`fail stage=push attempts=3 branch=${TARGET_BRANCH} checkout=${checkoutBranch || 'detached'} mode=${mode}`);
  finish(1);
}

const t = new Date();
try { fs.utimesSync(STATE, t, t); } catch { fs.writeFileSync(STATE, ''); }

// 여기부터는 덤이다. 실패해도 결과에 영향이 없다. 로컬 체크아웃이 대상 브랜치에 있고
// 빨리감기가 되면 맞춰 준다. 안 그러면 "behind origin/main N commits" 가 매일 쌓인다.
let sync = 'skip';
const gd = path.join(repo, '.git');
if (checkoutBranch === TARGET_BRANCH && !['rebase-merge', 'rebase-apply', 'MERGE_HEAD'].some(f => fs.existsSync(path.join(gd, f)))) {
  sync = git(['merge', '--ff-only', '-q', `origin/${TARGET_BRANCH}`]).ok ? 'ok' : 'fail';
}

emit(`ok fetch=page push=ok branch=${TARGET_BRANCH} checkout=${checkoutBranch || 'detached'} localsync=${sync} mode=${mode}`);
if (haveLock) fs.rmSync(LOCK, { recursive: true, force: true });
process.exit(0);
