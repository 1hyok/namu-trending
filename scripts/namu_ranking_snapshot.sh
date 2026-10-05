#!/bin/zsh
# macOS 진입점. 수집은 같은 폴더의 namu_ranking_snapshot.mjs 가 한다(윈도우와 공용).
# launchd plist 와 스킬이 이 경로를 부르므로 이름을 유지한다. 인자는 그대로 넘긴다(--scheduled).
#
# launchd 는 PATH 를 /usr/bin:/bin:/usr/sbin:/sbin 으로만 주고 ~/.zprofile 도 안 읽는다.
# node 는 Homebrew 경로에 있으므로 직접 찾는다. NAMU_NODE 로 바꿀 수 있다.

emulate -L zsh
for n in ${NAMU_NODE:-} /opt/homebrew/bin/node /usr/local/bin/node; do
  [[ -n $n && -x $n ]] && exec "$n" "${0:A:h}/namu_ranking_snapshot.mjs" "$@"
done
LOG=${NAMU_LOG:-$HOME/Library/Logs/namu-ranking-snapshot.log}
print -r -- "$(TZ=Asia/Seoul /bin/date "+%Y-%m-%dT%H:%M:%S+09:00") RESULT fail stage=node reason=not-found" >> "$LOG"
exit 1
