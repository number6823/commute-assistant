# 이동비서 본체: 알림창으로 묻고, 교통 MCP(PlayMCP)를 `claude -p` 로 불러 가장 빠른 차를 알려준다.
#   -Mode ask     퇴근 시각 예약(작업 스케줄러)이 부른다. "잔업 및 추가공부를 하시나요?"
#   -Mode remind  [예] 를 눌렀을 때 종료 10분 전에 스스로 다시 부른다 (-At 시각까지 기다린 뒤 경로 안내)
#   -Mode setup   집 주소 / 자주 있는 곳(학교·학원 등)을 새로 입력해 저장한다 (처음 설정, 이사, 오입력 수정)
# 집 주소는 사람마다 달라서 코드에 두지 않고 각자 PC 의 ~/.claude/commute/config.json 에만 저장한다.
# 교통 도구는 "지금 시각" 기준으로만 조회되므로, 늦게 퇴근하는 경우는 그 시각이 되었을 때 조회한다.

param(
    [ValidateSet('ask', 'remind', 'setup')][string]$Mode = 'ask',
    [string]$At = ''          # remind 모드: 경로를 조회할 시각 (ISO 문자열)
)

# 자식 `claude -p` 세션이 다시 이 스크립트나 인사 팝업을 부르지 않게 한다
if ($env:CLAUDE_GREET_SUMMARIZING) { exit 0 }

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir  = $PSScriptRoot
$popup      = Join-Path $scriptDir 'commute-popup.ps1'
$locScript  = Join-Path $scriptDir 'get-location.ps1'
$weatherScript = Join-Path $scriptDir 'get-weather.ps1'
$dataDir    = Join-Path $env:USERPROFILE '.claude\commute'
$configPath = Join-Path $dataDir 'config.json'
$timeoutSec = 90
$utf8NoBom  = New-Object System.Text.UTF8Encoding $false

New-Item -ItemType Directory -Force $dataDir | Out-Null

# ── 설정 (집 주소는 처음 한 번만 묻고 저장한다) ───────────────
function Get-Config {
    $cfg = [ordered]@{ home = ''; usual_place = ''; remind_minutes_before = 10; kma_key = '' }
    if (Test-Path $configPath) {
        $saved = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) { if ($null -ne $saved.$k) { $cfg[$k] = $saved.$k } }
    }
    return $cfg
}

function Save-Config($cfg) {
    [System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json), $utf8NoBom)
}

# ── 알림창 호출 (PowerShell 5.1 로 띄운다) ────────────────────
function Show-Popup([hashtable]$Params) {
    # 외부 프로그램에는 해시테이블 스플래팅이 안 되고, PS 5.1 은 빈 문자열 인자를 버리므로 직접 배열로 만든다
    $argList = @('-NoProfile', '-File', $popup)
    foreach ($k in $Params.Keys) {
        if ("$($Params[$k])" -eq '') { continue }
        $argList += "-$k"
        $argList += "$($Params[$k])"
    }
    $out = & powershell.exe @argList
    return ("$out").Trim()
}

# ── claude -p 호출: 프롬프트를 넣고 답 글자를 돌려받는다 ───────
function Invoke-Claude([string]$Prompt, [string[]]$Tools) {
    $work = Join-Path $env:TEMP 'claude-commute-work'
    New-Item -ItemType Directory -Force $work | Out-Null
    $stdinPath  = Join-Path $work 'in.txt'
    $stdoutPath = Join-Path $work 'out.txt'
    $stderrPath = Join-Path $work 'err.txt'
    [System.IO.File]::WriteAllText($stdinPath, $Prompt, $utf8NoBom)
    Remove-Item $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

    $env:CLAUDE_GREET_SUMMARIZING = '1'
    $claude = (Get-Command claude -ErrorAction Stop).Source
    $claudeArgs = @('-p', '--model', 'sonnet', '--no-session-persistence', '--setting-sources', 'local', '--disable-slash-commands')
    if ($Tools) { $claudeArgs += @('--allowedTools', ($Tools -join ',')) }
    $proc = Start-Process $claude -WorkingDirectory $work -WindowStyle Hidden -PassThru -ArgumentList $claudeArgs `
        -RedirectStandardInput $stdinPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (-not $proc.WaitForExit($timeoutSec * 1000)) { $proc.Kill(); return '' }
    if (-not (Test-Path $stdoutPath)) { return '' }
    return [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8).Trim()
}

# ── 현재 위치 -> 가장 가까운 역 이름 (못 구하면 빈 값) ─────────
function Get-NearbyStation {
    $json = & powershell.exe -NoProfile -File $locScript
    if (-not $json) { return @{ station = ''; source = '' } }
    $loc = "$json" | ConvertFrom-Json
    # IP 위치는 통신사 기준이라 시청 같은 도시 중심 좌표로 나오기 쉽다. 역을 추정해 봐야 항상 틀리므로 쓰지 않는다.
    if ($loc.source -eq 'ip') { return @{ station = ''; source = 'ip' } }
    $prompt = "위도 $($loc.lat), 경도 $($loc.lon). 수도권에서 이 위치와 가장 가까운 지하철역 이름 하나만 '역' 글자 없이 출력해. 다른 말은 쓰지 마. 확실하지 않으면 빈 줄만 출력해."
    $station = (Invoke-Claude $prompt $null) -split "`n" | Select-Object -First 1
    return @{ station = "$station".Trim(); source = $loc.source }
}

# ── 출발지 날씨 한 줄 (기상청 OpenAPI). 키가 없거나 실패하면 빈 값 ──
function Get-WeatherLine([string]$place, $cfg) {
    $key = if ($env:KMA_SERVICE_KEY) { $env:KMA_SERVICE_KEY } else { $cfg.kma_key }    # 키가 없어도 get-weather 가 Open-Meteo 로 대신한다
    $prev = $env:KMA_SERVICE_KEY
    $env:KMA_SERVICE_KEY = $key                  # 키는 명령줄이 아니라 환경변수로 넘긴다
    try { return ("$(& powershell.exe -NoProfile -File $weatherScript -Place $place)").Trim() }
    finally { $env:KMA_SERVICE_KEY = $prev }     # 뒤이어 뜨는 claude -p 에는 키를 물려주지 않는다
}

# ── 집 가는 길 안내 ───────────────────────────────────────────
function Show-Route {
    $cfg = Get-Config

    if (-not $cfg.home) {
        $home_ = Show-Popup @{ Mode = 'input'; Title = '집 주소'; Message = '도착지가 어디신가요?'; Sub = '집 근처 역이나 동네 이름을 적어 주세요. 한 번만 입력하면 저장해 둘게요.' }
        if (-not $home_) { return }
        $cfg.home = $home_
        Save-Config $cfg
    }

    $near = Get-NearbyStation
    $default = if ($near.station) { $near.station } else { $cfg.usual_place }
    $sub = switch ($near.source) {
        'windows' { '위치 서비스로 찾은 가장 가까운 역이에요. 다르면 고쳐 주세요.' }
        'ip'      { 'IP 위치는 부정확해서 쓰지 않았어요. 출발할 역/정류장을 적어 주세요.' }
        default   { '위치를 못 찾았어요. 출발할 역/정류장을 적어 주세요.' }
    }
    $origin = Show-Popup @{ Mode = 'input'; Title = '출발지'; Message = '지금 어디서 출발하세요?'; Sub = $sub; Default = $default }
    if (-not $origin) { return }
    if ($origin -ne $cfg.usual_place) { $cfg.usual_place = $origin; Save-Config $cfg }

    $now = Get-Date -Format 'HH:mm'
    $prompt = @"
transit-plan_journey 도구로 출발지 '$origin' 에서 도착지 '$($cfg.home)' 까지 조회해. 지금 시각은 $now 이다.
F/N/L 옵션 중 지금 탈 수 있는(🟢 또는 🟡) 가장 빠른 탑승 옵션 하나만 골라라.
'79994역 전', '+159987분' 처럼 말이 안 되는 값이 붙은 옵션은 무시해라.
출력은 두 줄 또는 세 줄:
1줄: HH:mm <탑승 장소> <지하철 호선 또는 버스번호> <방면> 있습니다. 서두르세요!   (처음 타는 것이 지하철인지 버스인지 '1호선', '66번 버스' 처럼 노선 이름에 드러나게 쓰고, 방면은 도구 결과의 '출발역→도착역' 표기를 써서 '소사 방면' 처럼 적어라)
2줄: 도착 예정 HH:mm · 소요 N분 · (환승이 있으면 환승 횟수)
3줄(선택): 결과의 '다른 경로 방안'에 버스만/지하철만 같은 대안이 있을 때만 쓴다. 대안의 소요 시간은 '현 경로 소요 + 대안에 적힌 +N분' 이다. 이 값이 지금 고른 옵션이 집에 도착하기까지 남은 시간(대기 포함)보다 5분 이상 짧으면 '버스(66번)가 더 빠를 수 있어요 (약 N분)' 처럼 한 줄로 알려라. 대안이 없거나 비슷하거나 더 느리면 3줄은 쓰지 마라.
이 외에는 어떤 설명도 덧붙이지 마라. 도구 결과에 없는 내용은 절대 지어내지 마라. 조회가 실패하면 1줄에 '경로를 찾지 못했어요', 2줄에 이유를 짧게 써라.
"@
    $tools = @('mcp__claude_ai_PlayMCP__transit-plan_journey', 'mcp__claude_ai_PlayMCP__transit-get_subway_arrival', 'mcp__claude_ai_PlayMCP__transit-get_bus_arrival')
    $answer = Invoke-Claude $prompt $tools
    if (-not $answer) { $answer = "경로를 찾지 못했어요`n응답이 없거나 시간이 초과됐어요." }

    $lines = @($answer -split "`r?`n" | Where-Object { $_.Trim() })
    $title = $lines[0]
    $detail = if ($lines.Count -gt 1) { $lines[1] } else { '' }
    if ($lines.Count -gt 2 -and $lines[2] -match '더 빠를 수 있어요') { $detail = "$detail / $($lines[2])" }    # 3줄은 '더 빠를 수 있어요' 힌트일 때만 쓰고, 모델이 덧붙인 설명은 버린다
    $weather = Get-WeatherLine $origin $cfg
    if ($weather) { $detail = (@($detail, $weather) | Where-Object { $_ }) -join ' / ' }
    [void](Show-Popup @{ Mode = 'info'; Title = '집 가는 길'; Message = $title; Sub = $detail; Seconds = 120 })
}

# ── "몇 시까지" 입력 해석: 20:30 / 2030 / 8시 30분 / 20시 -> 오늘의 DateTime (못 읽으면 $null) ─
function ConvertTo-EndTime([string]$text) {
    if ($text -notmatch '(\d{1,2})\s*[:시]?\s*(\d{2})?') { return $null }
    $h = [int]$Matches[1]
    $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
    if ($h -gt 23 -or $m -gt 59) { return $null }
    $t = (Get-Date).Date.AddHours($h).AddMinutes($m)
    # "8시 30분" 처럼 12시간제로 말한 저녁 시각: 이미 지났으면 오후로 본다
    if ($t -le (Get-Date) -and $h -lt 12) { $t = $t.AddHours(12) }
    return $t
}

# ── 진행 ──────────────────────────────────────────────────────
if ($Mode -eq 'setup') {
    $cfg = Get-Config
    $newHome = Show-Popup @{ Mode = 'input'; Title = '설정 1/2'; Message = '집이 어디세요?'; Sub = '집 근처 역이나 동네 이름을 적어 주세요.'; Default = $cfg.home }
    if (-not $newHome) { exit 0 }
    $newPlace = Show-Popup @{ Mode = 'input'; Title = '설정 2/2'; Message = '평소 퇴근/하교하는 곳은요?'; Sub = '학교·학원·직장 근처 역이나 정류장을 적어 주세요. 출발지 기본값으로 써요.'; Default = $cfg.usual_place }
    $newKey = Show-Popup @{ Mode = 'input'; Title = '설정 3/3 (선택)'; Message = '기상청 API 키가 있나요?'; Sub = '공공데이터포털 인증키를 붙여 넣으면 기상청 예보를 써요. 없으면 비워 두세요 (키 없는 날씨 서비스로 대신해요).' }
    $cfg.home = $newHome
    if ($newPlace) { $cfg.usual_place = $newPlace }
    if ($newKey) { $cfg.kma_key = $newKey }    # 비워 두면 기존 키를 유지한다
    Save-Config $cfg
    $weatherState = if ($cfg.kma_key) { '날씨: 기상청' } else { '날씨: Open-Meteo (키 없음)' }
    [void](Show-Popup @{ Mode = 'info'; Title = '설정 완료'; Message = "집: $($cfg.home)"; Sub = "출발지 기본값: $($cfg.usual_place) / $weatherState"; Seconds = 15 })
    exit 0
}

if ($Mode -eq 'remind') {
    $target = [datetime]::Parse($At)
    $wait = ($target - (Get-Date)).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Seconds ([int]$wait) }
    Show-Route
    exit 0
}

$answer = Show-Popup @{ Mode = 'yesno'; Title = '퇴근 시간'; Message = '잔업 및 추가공부를 하시나요?'; Sub = '아니요를 누르면 집 가는 길을 알려드려요.' }
switch ($answer) {
    'no' { Show-Route }
    'yes' {
        $end = $null
        for ($try = 0; $try -lt 2 -and -not $end; $try++) {
            $text = Show-Popup @{ Mode = 'input'; Title = '종료 시각'; Message = '몇 시까지 하시나요?'; Sub = '예: 20:30 (그 10분 전에 집 가는 길을 알려드려요)' }
            if (-not $text) { exit 0 }
            $end = ConvertTo-EndTime $text
            if ($end -and $end -le (Get-Date)) { $end = $null }
        }
        if (-not $end) { exit 0 }

        $cfg = Get-Config
        $remindAt = $end.AddMinutes(-[int]$cfg.remind_minutes_before)
        if ($remindAt -lt (Get-Date)) { $remindAt = Get-Date }
        $self = Join-Path $scriptDir 'commute.ps1'
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-File', "`"$self`"", '-Mode', 'remind', '-At', "`"$($remindAt.ToString('s'))`"")
        [void](Show-Popup @{ Mode = 'info'; Title = '예약 완료'; Message = "$($remindAt.ToString('HH:mm')) 에 다시 알려드릴게요"; Sub = "종료 $($end.ToString('HH:mm')) 기준이에요. 파이팅!"; Seconds = 15 })
    }
    default { }    # timeout: 아무것도 하지 않는다
}
