# namu-trending

나무위키 실시간 검색어를 수집해 Git 저장소에 기록하는 도구(macOS·Windows)와 키워드별 배경을 조사하는 스킬입니다.

## 실행

Node.js 22 이상(내장 WebSocket), Google Chrome(윈도우는 Edge 도 됨), Git과 원격 저장소 쓰기 권한이 필요합니다.

```sh
scripts/namu_ranking_snapshot.sh          # macOS
node scripts/namu_ranking_snapshot.mjs     # 공용
```

순위는 헤드리스 Chrome 으로 나무위키 대문을 띄워 실시간 검색어 카드에서 읽습니다. 예전 API `search.namu.wiki/api/ranking` 은 2026-10-04 에 DNS 에서 사라졌고, 지금은 페이지 스크립트가 서명 헤더를 붙여 암호화된 응답을 받아 카드에 그립니다. 그 헤더를 흉내 내지 않고 브라우저가 그린 결과만 읽습니다. `NAMU_CHROME` 으로 브라우저 경로를, `NAMU_PAGE_TIMEOUT`(초)으로 카드 대기 시간을 바꿀 수 있습니다.

이 명령은 네트워크 요청을 보내고 `origin/main`에 `ranking-latest.json`을 갱신하는 커밋을 push합니다. 공개 저장소에서는 수집 시각과 검색어가 공개됩니다. `NAMU_BRANCH`로 대상 브랜치를 바꿀 수 있습니다. Git 사용자 정보와 인증은 실행 전에 설정합니다.

수집기는 별도 임시 Git 인덱스로 원격 커밋을 만듭니다. 사용자의 다른 수정 파일은 그 커밋에 포함하지 않습니다. push 후 현재 브랜치가 대상 브랜치이고 빨리감기가 가능하면 로컬도 동기화합니다. 로컬 동기화에 실패해도 원격 수집 결과는 유지됩니다.

## 예약 실행

예약은 항상 켜져 있는 윈도우 PC 에 둡니다. 맥은 잠자기·종료로 슬롯을 놓칩니다(2026-10-04·05 의 실행은 깨어난 뒤 한 번씩만 돌았습니다).

### Windows

```powershell
powershell -File scripts\install_namu_snapshot_windows.ps1
powershell -File scripts\install_namu_snapshot_windows.ps1 -Status
```

작업 스케줄러 작업 `NamuRankingSnapshot` 을 06:00, 07:00, 07:45 와 로그온 때 돌립니다. 창이 뜨지 않게 `conhost.exe --headless` 로 감싸므로 작업 기록의 결과 코드는 늘 0 이고, 성공 여부는 `%USERPROFILE%\.namu-trending\namu-ranking-snapshot.log` 의 `RESULT` 줄로 봅니다. 로그와 상태 파일을 AppData 밖에 두는 이유는 Claude 앱(MSIX) 안에서 돌린 실행과 작업 스케줄러 실행이 같은 파일을 보게 하려는 것입니다.

### macOS

```sh
scripts/install_namu_snapshot_launchd.sh --emit > /tmp/namu-snapshot.plist
plutil -lint /tmp/namu-snapshot.plist
scripts/install_namu_snapshot_launchd.sh
scripts/install_namu_snapshot_launchd.sh --status
```

`--emit`은 설치할 plist를 표준 출력으로만 내보냅니다. 설치는 현재 사용자의 LaunchAgents에 설정을 저장합니다. 저장소 안에는 개인 경로가 담긴 plist를 만들지 않습니다. 연결된 임시 worktree에서는 설치하지 않습니다.

기존 기본 예약 시각은 기기의 로컬 시간으로 06:00, 07:00, 07:45이며 로그인 직후에도 실행합니다. `--scheduled` 실행은 최근 성공 후 20분 동안 중복 수집을 건너뜁니다. `NAMU_MIN_INTERVAL_MIN`, `NAMU_LOG`, `NAMU_STATE`, `NAMU_NET_TIMEOUT`으로 해당 설정을 조정할 수 있습니다.

실행 결과는 `~/Library/Logs/namu-ranking-snapshot.log`의 `START`와 `RESULT`에서 확인합니다. `launchctl print`의 실행 횟수는 적재 후 값이므로 특정 시점의 실행을 증명하지 않습니다.

## 스킬과 로컬 설정

`SKILL.md`는 현재 순위와 출처를 확인해 키워드별 이유를 정리하는 절차입니다. 프로젝트 안에서 이 정본 폴더를 연결해 사용하며 전역 스킬로 설치하지 않습니다.

개인 운영 기록과 생성된 launchd 설정, 로그는 Git에서 제외합니다. 기존 수집 스크립트의 동작과 스냅샷 형식은 유지합니다. 별도 오픈소스 라이선스는 부여하지 않았습니다.
