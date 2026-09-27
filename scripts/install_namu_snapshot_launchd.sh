#!/bin/zsh
# 나무위키 실검 스냅샷 launchd 작업을 설치·재설치하고 실제로 뜨는지 확인한다.
#
#   scripts/install_namu_snapshot_launchd.sh            설치(또는 재설치) 후 검증
#   scripts/install_namu_snapshot_launchd.sh --force    내용이 같아도 강제로 재등록
#   scripts/install_namu_snapshot_launchd.sh --emit     저장소 안 참조본(scripts/launchd/)만 갱신
#   scripts/install_namu_snapshot_launchd.sh --status   지금 상태만 본다
#
# plist는 현재 체크아웃 경로로 생성한다. 저장소를 옮기면 새 위치에서 다시 설치한다.

emulate -L zsh
setopt pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL=me.1hyok.namu-ranking-snapshot
REPO=${0:A:h:h}

# 워크트리에서 설치하면 그 경로가 plist 에 박힌다. 워크트리는 main 이 아닌 브랜치에 있고
# 나중에 지워지므로, 그렇게 걸린 작업은 매일 아침 조용히 실패하거나 아예 안 뜬다.
gitdir=$(git -C "$REPO" rev-parse --path-format=absolute --git-dir 2>/dev/null)
commondir=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [[ -n $gitdir && -n $commondir && $gitdir != $commondir ]]; then
  main_checkout=${commondir:h}
  print -u2 "여기는 연결된 워크트리다: $REPO"
  print -u2 "본 체크아웃에서 설치해야 한다:"
  print -u2 "  $main_checkout/scripts/${0:t}"
  exit 1
fi
SCRIPT=$REPO/scripts/namu_ranking_snapshot.sh
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
REF=$REPO/scripts/launchd/$LABEL.plist
LOG=$HOME/Library/Logs/namu-ranking-snapshot.log
DOMAIN=gui/$(id -u)

emit_plist() {
  /usr/bin/python3 - "$SCRIPT" "$REPO" "$LOG" "$HOME" <<'PY'
import plistlib, sys
script, repo, log, home = sys.argv[1:5]
plistlib.dump({
    "Label": "me.1hyok.namu-ranking-snapshot",
    "ProgramArguments": [script, "--scheduled"],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        # launchd 는 PATH 를 /usr/bin:/bin:/usr/sbin:/sbin 으로만 준다. 로그인 셸이 아니므로
        # ~/.zprofile 도 안 읽는다. git·python3·curl 이 전부 /usr/bin 에 있어 이대로 충분하다.
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": home,
        "LANG": "en_US.UTF-8",
    },
    # 여러 아침 슬롯을 두어 잠자기로 놓친 수집을 보완한다.
    "StartCalendarInterval": [
        {"Hour": 6, "Minute": 0},
        {"Hour": 7, "Minute": 0},
        {"Hour": 7, "Minute": 45},
    ],
    # 꺼져 있었다면 슬롯은 그냥 사라진다(잠자기와 달리 따라잡지 않는다).
    # 로그인·부팅 직후 한 번 돌려 스냅샷을 따라잡는다.
    "RunAtLoad": True,
    "StandardOutPath": log,
    "StandardErrorPath": log,
}, open("/dev/stdout", "wb"))
PY
}

case ${1:-install} in
  --status)
    ;;
  --emit)
    mkdir -p "${REF:h}"
    emit_plist > "$REF" || { print -u2 "plist 생성 실패"; exit 1 }
    plutil -lint "$REF" || exit 1
    print "참조본 갱신: $REF"
    exit 0
    ;;
  install|--force|"")
    [[ -x $SCRIPT ]] || { print -u2 "스크립트가 없거나 실행 권한이 없다: $SCRIPT"; exit 1 }
    mkdir -p "${PLIST:h}" "${REF:h}" "${LOG:h}"
    emit_plist > "$PLIST.new" || { print -u2 "plist 생성 실패"; exit 1 }
    plutil -lint "$PLIST.new" || exit 1

    # 내용이 같고 이미 적재돼 있으면 건드리지 않는다. bootstrap 할 때마다 macOS 가
    # "App Background Activity" 알림을 띄우므로, 상태만 보려고 돌린 실행이 알림을 만든다.
    if [[ ${1:-} != --force && -f $PLIST ]] \
       && cmp -s "$PLIST.new" "$PLIST" \
       && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      rm -f "$PLIST.new"
      cp "$PLIST" "$REF"
      print "이미 같은 내용으로 적재돼 있다. 재등록하지 않는다 (강제하려면 --force)."
    else
      mv "$PLIST.new" "$PLIST"
      cp "$PLIST" "$REF"
      launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null   # 안 떠 있으면 실패하는 게 정상이다
      # bootout 은 비동기다. 빠지기를 안 기다리고 bootstrap 하면 "Input/output error" 로 튕긴다.
      for _ in {1..50}; do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.1
      done
      launchctl bootstrap "$DOMAIN" "$PLIST" || { print -u2 "bootstrap 실패"; exit 1 }
      print "설치 완료: $PLIST"
    fi
    ;;
  *)
    print -u2 "모르는 인자: $1"; exit 2
    ;;
esac

print "\n--- launchctl print $DOMAIN/$LABEL ---"
launchctl print "$DOMAIN/$LABEL" 2>&1 | grep -E 'state|program|arguments|runs|last exit|Hour|Minute|path =' | sed 's/^/  /'
print "  (runs·last exit 는 '로드 이후' 값이라 돌았는지의 근거가 못 된다. 재부팅·로그인·재설치마다"
print "   0 으로 돌아가고, RunAtLoad 때문에 로드 직후 이미 1 이다. kickstart 는 실행 한 번에 1~2 오른다."
print "   실제로 돌았는지는 아래 로그의 START·RESULT 줄로 본다)"
print "\n--- 로그 마지막 10줄 ($LOG) ---"
tail -n 10 "$LOG" 2>/dev/null | sed 's/^/  /'
print "\n한 번 돌려 보려면:  launchctl kickstart -k $DOMAIN/$LABEL"
