# 윈도우 진입점. 수집은 같은 폴더의 namu_ranking_snapshot.mjs 가 한다(macOS 와 공용).
# 작업 스케줄러가 이 파일을 부른다. 인자는 그대로 넘긴다(--scheduled).
#
# winget 포터블 Node 는 버전 폴더(...\node-v26.7.0-win-x64)에 깔리고 사용자 PATH 에도 그 폴더가
# 박힌다. 업그레이드로 폴더가 바뀌면 PATH 로도 못 찾을 수 있으므로 설치 위치를 직접 훑는다.
# 순서: NAMU_NODE → PATH → winget 버전 폴더 중 최신 → 공식 설치본. 끝내 없으면 로그에 남긴다.
# 그냥 실패하면 conhost --headless 감싸기 때문에 작업 기록도 0 이라 아무 흔적이 없다.

$candidates = @()
if ($env:NAMU_NODE) { $candidates += $env:NAMU_NODE }
$onPath = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($onPath) { $candidates += $onPath.Source }
$wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
if (Test-Path $wingetRoot) {
  $candidates += Get-ChildItem -Path $wingetRoot -Directory -Filter 'OpenJS.NodeJS*' -ErrorAction SilentlyContinue |
    Get-ChildItem -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]($_.Name -replace '^node-v([\d.]+).*$', '$1') } catch { [version]'0.0' } } -Descending |
    ForEach-Object { Join-Path $_.FullName 'node.exe' }
}
$candidates += (Join-Path $env:ProgramFiles 'nodejs\node.exe')

$node = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if ($node) {
  & $node (Join-Path $PSScriptRoot 'namu_ranking_snapshot.mjs') @args
  exit $LASTEXITCODE
}

$log = if ($env:NAMU_LOG) { $env:NAMU_LOG } else { Join-Path $HOME '.namu-trending\namu-ranking-snapshot.log' }
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log)
$stamp = [DateTime]::UtcNow.AddHours(9).ToString('yyyy-MM-ddTHH:mm:ss') + '+09:00'
[IO.File]::AppendAllText($log, "$stamp RESULT fail stage=node reason=not-found`n")
exit 1
