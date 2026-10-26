# 현재 위치를 JSON 한 줄로 출력한다: {"source":"windows|ip","lat":..,"lon":..,"place":".."}
# 1) Windows 위치 서비스 (Wi-Fi 기반) -> 2) IP 위치 (시/구 단위로 부정확할 수 있음) 순으로 시도한다.
# 둘 다 실패하면 아무것도 출력하지 않는다 (호출한 쪽이 저장된 '자주 있는 곳'으로 대신한다).

$ErrorActionPreference = 'SilentlyContinue'

try {
    Add-Type -AssemblyName System.Device
    $watcher = New-Object System.Device.Location.GeoCoordinateWatcher([System.Device.Location.GeoPositionAccuracy]::Default)
    [void]$watcher.TryStart($false, [TimeSpan]::FromSeconds(5))
    $loc = $watcher.Position.Location
    if ($loc -and -not $loc.IsUnknown) {
        [pscustomobject]@{ source = 'windows'; lat = $loc.Latitude; lon = $loc.Longitude; place = '' } | ConvertTo-Json -Compress
        exit 0
    }
} catch { }

try {
    $ip = Invoke-RestMethod -Uri 'https://ipwho.is/' -TimeoutSec 5
    if ($ip.success) {
        [pscustomobject]@{ source = 'ip'; lat = $ip.latitude; lon = $ip.longitude; place = "$($ip.region) $($ip.city)".Trim() } | ConvertTo-Json -Compress
    }
} catch { }
