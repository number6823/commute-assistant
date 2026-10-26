# 출발지 날씨를 한 줄로 출력한다. 예) "곧 비 예보 (19시쯤) · 우산 챙기세요 · 기온 12도"
# 기상청 단기예보 조회서비스(공공데이터포털)의 초단기예보(getUltraSrtFcst)를 쓴다.
#   장소 이름 -> 좌표 (OpenStreetMap Nominatim, 키 없음) -> 기상청 격자 nx,ny -> 초단기예보 -> 요약
# 서비스키는 환경변수 KMA_SERVICE_KEY 에서 읽는다 (commute.ps1 이 config.json 의 kma_key 를 넣어 준다).
# 키가 없거나 기상청 호출이 실패하면 키 없는 Open-Meteo 로 대신한다.
# 어느 단계든 실패해도 아무것도 출력하지 않는다 (날씨는 있으면 좋은 정보일 뿐, 길 안내를 막지 않는다).
#   -GridOnly  키 없이 장소 -> 좌표 -> 격자까지만 확인한다 (점검용)

param(
    [string]$Place = '',
    [switch]$GridOnly
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$timeoutSec = 8

# ── 위경도 -> 기상청 격자 (기상청 공식 Lambert 변환식) ─────────
function ConvertTo-KmaGrid([double]$lat, [double]$lon) {
    $re = 6371.00877 / 5.0                      # 지구 반경 / 격자 간격(km)
    $d2r = [Math]::PI / 180
    $slat1 = 30 * $d2r; $slat2 = 60 * $d2r      # 표준 위도
    $olon = 126 * $d2r; $olat = 38 * $d2r       # 기준점
    $xo = 43; $yo = 136                         # 기준점 격자 좌표

    $sn = [Math]::Tan([Math]::PI * 0.25 + $slat2 * 0.5) / [Math]::Tan([Math]::PI * 0.25 + $slat1 * 0.5)
    $sn = [Math]::Log([Math]::Cos($slat1) / [Math]::Cos($slat2)) / [Math]::Log($sn)
    $sf = [Math]::Pow([Math]::Tan([Math]::PI * 0.25 + $slat1 * 0.5), $sn) * [Math]::Cos($slat1) / $sn
    $ro = $re * $sf / [Math]::Pow([Math]::Tan([Math]::PI * 0.25 + $olat * 0.5), $sn)
    $ra = $re * $sf / [Math]::Pow([Math]::Tan([Math]::PI * 0.25 + $lat * $d2r * 0.5), $sn)

    $theta = $lon * $d2r - $olon
    if ($theta -gt [Math]::PI)  { $theta -= 2 * [Math]::PI }
    if ($theta -lt -[Math]::PI) { $theta += 2 * [Math]::PI }
    $theta *= $sn

    return @{
        nx = [int][Math]::Floor($ra * [Math]::Sin($theta) + $xo + 0.5)
        ny = [int][Math]::Floor($ro - $ra * [Math]::Cos($theta) + $yo + 0.5)
    }
}

# ── 장소 이름 -> 위경도 (Nominatim 은 User-Agent 필수, 초당 1회 이하) ──
function Get-PlaceLatLon([string]$name) {
    $url = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=kr&q=' + [uri]::EscapeDataString($name)
    $res = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'commute-assistant-plugin/0.1' } -TimeoutSec $timeoutSec
    if (-not $res -or @($res).Count -eq 0) { return $null }
    return @{ lat = [double]@($res)[0].lat; lon = [double]@($res)[0].lon }
}

# ── 초단기예보 항목 -> 한 줄 요약 ────────────────────────────
# PTY(강수형태): 0 없음, 1 비, 2 비/눈, 3 눈, 5 빗방울, 6 빗방울눈날림, 7 눈날림.  SKY: 1 맑음, 3 구름많음, 4 흐림
function Format-Weather($items) {
    $slots = @($items | Select-Object -ExpandProperty fcstTime -Unique | Sort-Object | Select-Object -First 3)    # 앞으로 약 3시간
    if (-not $slots) { return '' }
    $near = $items | Where-Object { $slots -contains $_.fcstTime }

    $temp = ($near | Where-Object { $_.category -eq 'T1H' } | Sort-Object fcstTime | Select-Object -First 1).fcstValue
    $tempText = if ($null -ne $temp -and $temp -ne '') { " · 기온 $([int][double]$temp)도" } else { '' }

    $rain = $near | Where-Object { $_.category -eq 'PTY' -and @('1', '2', '5', '6') -contains "$($_.fcstValue)" } | Sort-Object fcstTime | Select-Object -First 1
    if ($rain) { return "곧 비 예보 ($($rain.fcstTime.Substring(0, 2))시쯤) · 우산 챙기세요$tempText" }

    $snow = $near | Where-Object { $_.category -eq 'PTY' -and @('3', '7') -contains "$($_.fcstValue)" } | Sort-Object fcstTime | Select-Object -First 1
    if ($snow) { return "곧 눈 예보 ($($snow.fcstTime.Substring(0, 2))시쯤) · 따뜻하게 입으세요$tempText" }

    $sky = ($near | Where-Object { $_.category -eq 'SKY' } | Sort-Object fcstTime | Select-Object -First 1).fcstValue
    $skyText = switch ("$sky") { '1' { '맑음' } '3' { '구름 많음' } '4' { '흐림' } default { '' } }
    if (-not $skyText -and -not $tempText) { return '' }
    return ("$skyText$tempText" -replace '^ · ', '')
}

# ── Open-Meteo (키 없음): 기상청 키가 없거나 막혔을 때 쓰는 대체 ──
# WMO 날씨 코드: 0 맑음, 1 대체로 맑음, 2 구름 조금, 3 흐림, 45/48 안개, 51~67 이슬비·비, 71~77 눈, 80~82 소나기, 85~86 눈 소나기, 95~99 뇌우
function Format-OpenMeteo($hourly) {
    $n = [Math]::Min(3, @($hourly.time).Count)    # 앞으로 약 3시간
    if ($n -lt 1) { return '' }
    $tempText = " · 기온 $([int][Math]::Round([double]$hourly.temperature_2m[0]))도"
    $rainCodes = @(51..67) + @(80, 81, 82, 95, 96, 99)
    $snowCodes = @(71..77) + @(85, 86)

    for ($i = 0; $i -lt $n; $i++) {
        $code = [int]$hourly.weather_code[$i]
        $hour = ([string]$hourly.time[$i]).Substring(11, 2)
        if ($rainCodes -contains $code -or [double]$hourly.precipitation[$i] -ge 0.2) { return "곧 비 예보 (${hour}시쯤) · 우산 챙기세요$tempText" }
        if ($snowCodes -contains $code) { return "곧 눈 예보 (${hour}시쯤) · 따뜻하게 입으세요$tempText" }
    }
    $code0 = [int]$hourly.weather_code[0]
    $skyText = if ($code0 -le 1) { '맑음' } elseif ($code0 -eq 2) { '구름 조금' } elseif ($code0 -eq 3) { '흐림' } elseif ($code0 -in 45, 48) { '안개' } else { '' }
    return ("$skyText$tempText" -replace '^ · ', '')
}

function Get-OpenMeteoWeather($pos) {
    $url = "https://api.open-meteo.com/v1/forecast?latitude=$($pos.lat)&longitude=$($pos.lon)" +
        '&hourly=temperature_2m,precipitation,weather_code&forecast_hours=4&timezone=Asia%2FSeoul'
    $res = Invoke-RestMethod -Uri $url -TimeoutSec $timeoutSec
    return Format-OpenMeteo $res.hourly
}

# ── 기상청 초단기예보 ──────────────────────────────────────────
function Get-KmaWeather($pos, [string]$key) {
    $grid = ConvertTo-KmaGrid $pos.lat $pos.lon

    # 초단기예보는 매시 30분 기준 자료가 45분 뒤부터 조회된다
    $base = (Get-Date).AddMinutes(-45)
    $k = if ($key -match '%') { $key } else { [uri]::EscapeDataString($key) }    # 인코딩된 키/디코딩된 키 둘 다 받는다
    $url = 'https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getUltraSrtFcst' +
        "?serviceKey=$k&pageNo=1&numOfRows=60&dataType=JSON" +
        "&base_date=$($base.ToString('yyyyMMdd'))&base_time=$($base.ToString('HH'))30&nx=$($grid.nx)&ny=$($grid.ny)"
    $res = Invoke-RestMethod -Uri $url -TimeoutSec $timeoutSec
    if ($res.response.header.resultCode -ne '00') { return '' }    # 키 오류 등은 XML 로 오기도 해서 여기서 걸러진다
    return Format-Weather @($res.response.body.items.item)
}

# 기상청 키가 있으면 기상청을 먼저 쓰고, 키가 없거나 실패하면 Open-Meteo 로 넘어간다
function Get-Weather([string]$place, [string]$key) {
    $pos = Get-PlaceLatLon $place
    if (-not $pos) { return '' }
    if ($key) {
        try { $line = Get-KmaWeather $pos $key; if ($line) { return $line } } catch { }
    }
    try { return Get-OpenMeteoWeather $pos } catch { return '' }
}

# 점-실행(. .\get-weather.ps1)하면 함수만 불러오고 본문은 돌지 않는다 (테스트용)
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if (-not $Place) { exit 0 }
    if ($GridOnly) {
        $pos = Get-PlaceLatLon $Place
        if (-not $pos) { Write-Output '장소를 찾지 못했어요'; exit 0 }
        $g = ConvertTo-KmaGrid $pos.lat $pos.lon
        Write-Output "lat=$($pos.lat) lon=$($pos.lon) nx=$($g.nx) ny=$($g.ny)"
        exit 0
    }
    $line = Get-Weather $Place $env:KMA_SERVICE_KEY
    if ($line) { Write-Output $line }
} catch { }
