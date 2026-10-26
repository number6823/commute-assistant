# 평일(월~금) 18:00 에 이동비서 알림창을 띄우는 작업 스케줄러 항목을 등록한다.
#   -EnsureOnly  SessionStart 훅이 부른다. 이미 같은 경로로 등록돼 있으면 아무것도 하지 않는다.
#   -Remove      등록한 항목을 지운다.
#   -Time        알림 시각 (기본 18:00)
# PC 가 꺼져 있던 시간의 알림은 따라잡지 않는다 (StartWhenAvailable 를 켜지 않는다).

param(
    [switch]$EnsureOnly,
    [switch]$Remove,
    [string]$Time = '18:00'
)

# 훅이 부르는 경우 자식 `claude -p` 세션에서는 아무것도 하지 않는다
if ($env:CLAUDE_GREET_SUMMARIZING) { exit 0 }

$ErrorActionPreference = 'Stop'
$taskName = 'ClaudeCommuteAssistant'
$script   = Join-Path $PSScriptRoot 'commute.ps1'
$arguments = "-NoProfile -WindowStyle Hidden -File `"$script`" -Mode ask"

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($Remove) {
    if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Output '삭제했어요.' }
    else { Write-Output '등록된 항목이 없어요.' }
    exit 0
}

# 같은 시각·같은 경로로 이미 등록돼 있으면 그대로 둔다 (플러그인 경로가 바뀌었을 때만 다시 등록)
if ($existing) {
    $sameArgs = $existing.Actions[0].Arguments -eq $arguments
    $sameTime = $existing.Triggers[0].StartBoundary -like "*T$($Time):00*"
    if ($sameArgs -and $sameTime) {
        if (-not $EnsureOnly) { Write-Output '이미 등록돼 있어요.' }
        exit 0
    }
}

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $Time
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive    # 화면에 알림창을 띄워야 하므로 로그온한 사용자로 실행

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output "평일 $Time 에 실행되도록 등록했어요."
