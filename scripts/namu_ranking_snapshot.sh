#!/bin/zsh
# 나무위키 실검을 받아 별도 Git 인덱스로 원격 스냅샷 커밋을 만든다.
# 현재 작업 트리의 수정은 커밋에 포함하지 않는다.
# --scheduled는 최근 성공 후 NAMU_MIN_INTERVAL_MIN분 동안 중복 수집을 건너뛴다.
# 수동 실행은 새로 수집하며, 네트워크 요청과 origin/<NAMU_BRANCH> push를 수행한다.

emulate -L zsh
setopt pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export GIT_TERMINAL_PROMPT=0        # 자격증명이 없으면 물어보지 말고 바로 실패해야 한다
export GIT_ASKPASS=/usr/bin/false   # GUI 로 물어보는 경로도 막는다. launchd 에서 멈추면 아무도 모른다

if [[ -z ${HOME:-} ]]; then
  HOME=$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  export HOME
fi

LOG=${NAMU_LOG:-$HOME/Library/Logs/namu-ranking-snapshot.log}
TARGET_BRANCH=${NAMU_BRANCH:-main}
# 20분인 이유: 슬롯 간격이 가장 좁은 데가 07:00~07:45 로 45분이다. 창을 40분으로 잡으면
# 07:00 슬롯이 깨어나느라 6분만 밀려도 07:45 가 통째로 건너뛰어진다. 이 값은 RunAtLoad 가
# 슬롯 직후에 또 받는 것만 막으면 되므로 넉넉히 작아도 된다.
MIN_INTERVAL_MIN=${NAMU_MIN_INTERVAL_MIN:-20}
STATE=${NAMU_STATE:-$HOME/Library/Caches/me.1hyok.namu-ranking-snapshot.last}
# 락 경로는 고정한다. TMPDIR 은 실행 경로(launchd·로그인 셸·래퍼)마다 달라질 수 있어
# 그 위에 락을 두면 손으로 돌린 것과 예약 실행이 서로를 못 본다.
LOCK=$HOME/Library/Caches/me.1hyok.namu-ranking-snapshot.lock
NET_TIMEOUT=${NAMU_NET_TIMEOUT:-60}
SNAP=ranking-latest.json
API=https://search.namu.wiki/api/ranking

mode=manual
[[ ${1:-} == --scheduled ]] && mode=scheduled

ts() { TZ=Asia/Seoul /bin/date "+%Y-%m-%dT%H:%M:%S+09:00" }

/bin/mkdir -p "${LOG:h}" "${LOCK:h}"
# 로그가 무한정 자라지 않게 500KB 넘으면 마지막 2000줄만 남긴다.
# 자리에서 잘라 넣는다. mv 로 갈아끼우면 launchd 가 이미 열어 둔 stdout/stderr 는
# 사라진 inode 를 계속 붙들어, 스크립트가 죽을 때 나오는 메시지가 통째로 없어진다.
if [[ -f $LOG ]] && (( $(/usr/bin/stat -f%z "$LOG") > 512000 )); then
  rot=$LOG.$$.rotated          # 이름에 pid 를 넣는다. 손으로 돌린 것과 예약 실행이 겹치면 같은 임시 파일을 밟는다
  if /usr/bin/tail -n 2000 "$LOG" > "$rot" 2>/dev/null; then
    /bin/cat "$rot" > "$LOG"
    /bin/rm -f "$rot"
  fi
fi

log() { print -r -- "$(ts) $*" >> "$LOG" }

have_lock=0
result_written=0
tmp=
tmpidx=

emit() {
  (( result_written )) && return 0
  result_written=1
  log "RESULT $*"
}

cleanup() {
  emit "fail stage=aborted mode=$mode"      # 여기까지 왔으면 위에서 RESULT 를 못 쓰고 죽은 것이다
  [[ -n $tmp ]] && /bin/rm -f "$tmp"
  [[ -n $tmpidx ]] && /bin/rm -f "$tmpidx"
  (( have_lock )) && /bin/rm -rf "$LOCK"
  return 0
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# macOS 에는 timeout(1) 이 없다. 네트워크를 타는 git 은 매달릴 수 있어 직접 시계를 붙인다.
# 매달린 채로 두면 RESULT 가 안 남는 것은 물론, launchd 가 같은 label 을 하나만 띄우므로
# 그 뒤 슬롯까지 전부 삼킨다.
run_timed() {
  local secs=$1; shift
  "$@" &
  local pid=$!
  { /bin/sleep "$secs"; /bin/kill -TERM "$pid" 2>/dev/null; /bin/sleep 5; /bin/kill -KILL "$pid" 2>/dev/null } &
  local wd=$!
  wait "$pid"; local rc=$?
  /bin/kill "$wd" 2>/dev/null
  return $rc
}

git_net() { run_timed "$NET_TIMEOUT" git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 -c credential.interactive=false "$@" }

log "START mode=$mode pid=$$"

# 07:45 슬롯과 RunAtLoad 가 같은 순간에 뜰 수 있어 겹쳐 도는 것을 막는다.
if /bin/mkdir "$LOCK" 2>/dev/null; then
  have_lock=1
else
  holder=$(/bin/cat "$LOCK/pid" 2>/dev/null)
  if [[ -n $holder ]] && /bin/kill -0 "$holder" 2>/dev/null; then
    emit "skip reason=locked holder=$holder mode=$mode"      # 진짜로 살아 있는 실행이다
    exit 0
  fi
  /bin/rm -rf "$LOCK" && /bin/mkdir "$LOCK" 2>/dev/null && have_lock=1   # 죽은 락이면 뺏는다
fi
if (( ! have_lock )); then
  emit "skip reason=lock-unavailable mode=$mode"
  exit 0
fi
print -r -- "$$" > "$LOCK/pid"

cd "${0:A:h}/.." 2>/dev/null || { emit "fail stage=cd mode=$mode"; exit 1; }
repo=$PWD
checkout_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)

# 신선도는 마지막 성공 시각으로 본다. 작업 트리의 파일은 일부러 안 건드리므로
# 그 파일의 시각은 origin/main 에 실제로 올라간 것보다 낡아 있을 수 있다.
if [[ $mode == scheduled && -f $STATE ]]; then
  age_min=$(( ( $(/bin/date +%s) - $(/usr/bin/stat -f%m "$STATE") ) / 60 ))
  if (( age_min >= 0 && age_min < MIN_INTERVAL_MIN )); then
    emit "skip reason=fresh age_min=$age_min mode=$mode"
    exit 0
  fi
fi

# 깨어난 직후엔 Wi-Fi 가 아직 안 올라와 있을 수 있어 세 번 시도한다.
tmp=$(/usr/bin/mktemp -t namu-ranking) || { emit "fail stage=mktemp mode=$mode"; exit 1; }
http=000
for attempt in 1 2 3; do
  http=$(/usr/bin/curl -sS -m 20 -o "$tmp" -w '%{http_code}' \
    -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36" \
    -H "Accept: application/json" -H "Accept-Language: ko-KR,ko;q=0.9" -H "Referer: https://namu.wiki/" \
    "$API" 2>>"$LOG") || http=000
  [[ $http == 200 ]] && break
  log "FETCH attempt=$attempt http=$http"
  (( attempt < 3 )) && /bin/sleep 10
done
if [[ $http != 200 ]]; then
  emit "fail stage=fetch http=$http attempts=3 mode=$mode"
  exit 1
fi

# 200 이어도 차단 페이지(HTML)가 올 수 있다. 배열인지, 문자열만 들었는지까지 본다.
now=$(ts)
payload=$(/usr/bin/mktemp -t namu-ranking-json) || { emit "fail stage=mktemp mode=$mode"; exit 1; }
if ! rank=$(/usr/bin/python3 - "$now" "$tmp" "$payload" 2>>"$LOG" <<'PY'
import json, sys
now, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
arr = json.load(open(src, encoding="utf-8"))
assert isinstance(arr, list) and len(arr) >= 5, repr(arr)[:200]
assert all(isinstance(x, str) and x.strip() for x in arr), repr(arr)[:200]
with open(dst, "w", encoding="utf-8") as f:
    json.dump({"fetched_at": now, "source": "https://search.namu.wiki/api/ranking", "ranking": arr},
              f, ensure_ascii=False, indent=2)
    f.write("\n")
print(" ".join(arr))
PY
); then
  /bin/rm -f "$payload"
  emit "fail stage=parse http=$http mode=$mode"
  exit 1
fi
log "RANK $rank"

# origin/main 위에 스냅샷 커밋 하나를 만들어 그것만 올린다. 그 사이 남이 push 했으면 다시 얹는다.
push=fail
for attempt in 1 2 3; do
  if ! git_net fetch -q origin "$TARGET_BRANCH" 2>>"$LOG"; then
    log "FETCH-GIT attempt=$attempt 실패"
    continue
  fi
  base=$(git rev-parse FETCH_HEAD 2>/dev/null) || { log "rev-parse FETCH_HEAD 실패"; continue }
  blob=$(git hash-object -w "$payload" 2>>"$LOG") || { log "hash-object 실패"; continue }
  tmpidx=$(/usr/bin/mktemp -u -t namu-ranking-idx)
  if ! GIT_INDEX_FILE=$tmpidx git read-tree "$base" 2>>"$LOG"; then log "read-tree 실패"; /bin/rm -f "$tmpidx"; continue; fi
  if ! GIT_INDEX_FILE=$tmpidx git update-index --add --cacheinfo 100644,"$blob","$SNAP" 2>>"$LOG"; then log "update-index 실패"; /bin/rm -f "$tmpidx"; continue; fi
  tree=$(GIT_INDEX_FILE=$tmpidx git write-tree 2>>"$LOG") || { log "write-tree 실패"; /bin/rm -f "$tmpidx"; continue }
  /bin/rm -f "$tmpidx"; tmpidx=
  commit=$(git commit-tree "$tree" -p "$base" -m "chore: 나무위키 실검 스냅샷 $now" 2>>"$LOG") \
    || { log "commit-tree 실패 (git 사용자 설정 확인)"; continue }
  if git_net push -q origin "$commit":"refs/heads/$TARGET_BRANCH" 2>>"$LOG"; then
    push=ok
    log "PUSH ok base=${base:0:7} commit=${commit:0:7} attempt=$attempt"
    break
  fi
  log "PUSH attempt=$attempt 거절 - origin 이 움직였다. 다시 얹는다"
done
/bin/rm -f "$payload"

if [[ $push != ok ]]; then
  emit "fail stage=push http=$http attempts=3 branch=$TARGET_BRANCH checkout=${checkout_branch:-detached} mode=$mode"
  exit 1
fi

/usr/bin/touch "$STATE"

# 여기부터는 덤이다. 실패해도 결과에 영향이 없다. 로컬 체크아웃이 main 에 있고 빨리감기가
# 되면 맞춰 준다. 안 그러면 사용자 눈에 "behind origin/main N commits" 가 매일 쌓인다.
sync=skip
if [[ $checkout_branch == "$TARGET_BRANCH" && ! -d .git/rebase-merge && ! -d .git/rebase-apply && ! -f .git/MERGE_HEAD ]]; then
  if run_timed 30 git merge --ff-only -q "origin/$TARGET_BRANCH" 2>>"$LOG"; then sync=ok; else sync=fail; fi
fi

emit "ok http=$http push=ok branch=$TARGET_BRANCH checkout=${checkout_branch:-detached} localsync=$sync mode=$mode"
exit 0
