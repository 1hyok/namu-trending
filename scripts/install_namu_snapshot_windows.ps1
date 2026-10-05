# 나무위키 실검 스냅샷을 윈도우 작업 스케줄러에 설치·재설치하고 상태를 본다.
#
#   powershell -File scripts\install_namu_snapshot_windows.ps1            설치(또는 재설치)
#   powershell -File scripts\install_namu_snapshot_windows.ps1 -Status    지금 상태만 본다
#   powershell -File scripts\install_namu_snapshot_windows.ps1 -Uninstall 작업을 지운다
#
# 작업은 현재 체크아웃 경로로 만든다. 저장소를 옮기면 새 위치에서 다시 설치한다.
# 창이 뜨면 전면 게임·작업의 포커스를 뺏으므로 conhost --headless 로 감싼다. 그 대신 작업
# 기록의 결과 코드는 늘 0 이라, 성공 여부는 로그의 RESULT 줄로 본다.
param([switch]$Status, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$TaskName = 'NamuRankingSnapshot'
$Repo = Split-Path -Parent $PSScriptRoot
$Script = Join-Path $PSScriptRoot 'namu_ranking_snapshot.mjs'
$Log = if ($env:NAMU_LOG) { $env:NAMU_LOG } else { Join-Path $HOME '.namu-trending\namu-ranking-snapshot.log' }

function Show-Status {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t) { Write-Output "작업 없음: $TaskName"; return }
  $i = $t | Get-ScheduledTaskInfo
  Write-Output "state=$($t.State) last=$($i.LastRunTime) next=$($i.NextRunTime)"
  Write-Output "action=$($t.Actions[0].Execute) $($t.Actions[0].Arguments)"
  if (Test-Path $Log) { Get-Content $Log -Tail 200 | Select-String -Pattern ' (START|RESULT) ' | Select-Object -Last 6 | ForEach-Object { $_.Line } }
}

if ($Status) { Show-Status; exit 0 }
if ($Uninstall) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Output "지움: $TaskName"; exit 0 }

# 연결된 워크트리에서 설치하면 그 경로가 작업에 박힌다. 워크트리는 나중에 지워진다.
$gitDir = (git -C $Repo rev-parse --path-format=absolute --git-dir).Trim()
$commonDir = (git -C $Repo rev-parse --path-format=absolute --git-common-dir).Trim()
if ($gitDir -ne $commonDir) { Write-Error "여기는 연결된 워크트리다: $Repo. 본 체크아웃에서 설치해야 한다."; exit 1 }

$Node = if ($env:NAMU_NODE) { $env:NAMU_NODE } else { (Get-Command node -ErrorAction Stop).Source }
$Conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'

$action = New-ScheduledTaskAction -Execute $Conhost -Argument "--headless `"$Node`" `"$Script`" --scheduled" -WorkingDirectory $Repo
# 여러 아침 슬롯을 두어 한 번 놓쳐도 보완한다. 시각은 이 기기의 로컬 시간이다.
$triggers = @(
  (New-ScheduledTaskTrigger -Daily -At '06:00'),
  (New-ScheduledTaskTrigger -Daily -At '07:00'),
  (New-ScheduledTaskTrigger -Daily -At '07:45'),
  (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME")
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
# 로그온한 사용자로 돈다. git 자격(Git Credential Manager)과 사용자 Chrome 경로를 그대로 쓰기 위해서다.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
  -Description 'namu-trending: 나무위키 실검 스냅샷을 origin 에 push 한다' -Force | Out-Null
Write-Output "설치: $TaskName"
Show-Status
