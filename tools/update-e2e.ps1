# MakeUpdate end-to-end test (PowerShell 5.1, pure ASCII). Never contacts GitHub and never runs a real
# installer: a fake GitHub (python http.server on 127.0.0.1) serves the release JSON + assets, and the
# "setup" / "app" are tools/update-e2e-fake.zig, which only writes a marker file. TEMP and LOCALAPPDATA
# point into a private temp folder; every process started here is stopped and the folder is removed.
#   powershell -ExecutionPolicy Bypass -File tools\update-e2e.ps1 [-Optimize ReleaseSafe] [-NoGui]
param([string]$Optimize = 'Debug', [switch]$NoGui)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'imgui-auto.ps1')
$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
if (-not (Test-Path $zig)) { $zig = 'zig' }
$python = (& py -3.12 -c 'import sys; print(sys.executable)').Trim()

$work = Join-Path ([IO.Path]::GetTempPath()) ('mkupd-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$srv = Join-Path $work 'srv'
$app = Join-Path $work 'app'
$marks = Join-Path $work 'marks'
$tmp = Join-Path $work 'tmp'
$lad = Join-Path $work 'lad'
foreach ($d in @($work, $srv, $app, $marks, $tmp, $lad, "$srv\dl", "$srv\repos\MakeMD\Demo\releases\tags")) { $null = New-Item -ItemType Directory -Force -Path $d }

$own = New-Object System.Collections.ArrayList   # processes started by this script
$savedEnv = @{}
function Set-TestEnv([string]$Name, $Value) {
    if (-not $savedEnv.ContainsKey($Name)) { $savedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name) }
    [Environment]::SetEnvironmentVariable($Name, $Value)   # process scope; $null removes
}
function Check($cond, [string]$what) { if (-not $cond) { throw "check failed: $what" } else { Write-Host "  ok  $what" } }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }

# Runs the updater, returns exit code + the parsed JSON line.
function Invoke-Updater([string]$Exe, [string[]]$A) {
    $out = @(& $Exe @A)
    $code = $LASTEXITCODE
    if ($out.Count -lt 1) { throw "no output from $Exe $($A -join ' ') (exit $code)" }
    [pscustomobject]@{ Code = $code; J = ($out[0] | ConvertFrom-Json); Raw = $out[0] }
}
function Start-Dummy([int]$Seconds) {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', "Start-Sleep -Seconds $Seconds") -WindowStyle Hidden -PassThru
    $null = $own.Add($p)
    $p
}
function Wait-File([string]$Path, [int]$Ms = 5000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while (-not (Test-Path $Path)) { if ((Get-Date) -gt $deadline) { return $false }; Start-Sleep -Milliseconds 100 }
    $true
}

$ok = $false
try {
    # ---- build (before TEMP/LOCALAPPDATA move: zig keeps its cache there)
    Push-Location $root
    try {
        & $zig build demo "-Doptimize=$Optimize"
        if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" }
        & $zig build-exe tools\update-e2e-fake.zig -O ReleaseSmall "-femit-bin=$work\fake.exe"
        if ($LASTEXITCODE -ne 0) { throw "building the fake exe failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
    $updater = Join-Path $root 'zig-out\bin\MakeUpdate.exe'
    Write-Host ("MakeUpdate.exe ({0}): {1:N0} bytes" -f $Optimize, (Get-Item $updater).Length)

    # ---- fake GitHub on a free loopback port
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    $base = "http://127.0.0.1:$port"
    Copy-Item "$work\fake.exe" "$srv\dl\Demo-Setup-1.2.0.exe"
    $hash = (Get-FileHash "$srv\dl\Demo-Setup-1.2.0.exe" -Algorithm SHA256).Hash   # upper case, like a PowerShell publish script
    Write-Utf8 "$srv\dl\SHA256SUMS.txt" ("{0}  Demo-Setup-1.2.0.exe`r`n{1}  Demo-1.2.0-portable.zip`r`n" -f $hash, ('0' * 64))
    $size = (Get-Item "$srv\dl\Demo-Setup-1.2.0.exe").Length
    $rel = '{"tag_name":"v1.2.0","html_url":"BASE/MakeMD/Demo/releases/tag/v1.2.0","draft":false,"prerelease":false,"body":"Fixes","assets":[' +
        '{"name":"Demo-Setup-1.2.0.exe","browser_download_url":"BASE/dl/Demo-Setup-1.2.0.exe","size":SIZE},' +
        '{"name":"SHA256SUMS.txt","browser_download_url":"BASE/dl/SHA256SUMS.txt","size":200}]}'
    $rel = $rel.Replace('BASE', $base).Replace('SIZE', "$size")
    Write-Utf8 "$srv\repos\MakeMD\Demo\releases\latest" $rel
    Write-Utf8 "$srv\repos\MakeMD\Demo\releases\tags\v1.2.0" $rel
    # Hostile / redirecting releases: MakeMD/<Name> gets a "latest" release with the given setup + SHA256SUMS.txt URLs.
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $hop = $l.LocalEndpoint.Port; $l.Stop()
    function Write-Release([string]$Name, [string]$SetupUrl, [string]$SumsUrl) {
        $null = New-Item -ItemType Directory -Force -Path "$srv\repos\MakeMD\$Name\releases"
        Write-Utf8 "$srv\repos\MakeMD\$Name\releases\latest" ('{"tag_name":"v1.2.0","html_url":"' + $base + '/p","assets":[' +
            '{"name":"' + $Name + '-Setup-1.2.0.exe","browser_download_url":"' + $SetupUrl + '"},' +
            '{"name":"SHA256SUMS.txt","browser_download_url":"' + $SumsUrl + '"}]}')
    }
    Write-Release 'EvilSetup' 'http://evil.invalid/x.exe' "$base/dl/SHA256SUMS.txt"
    Write-Release 'EvilSums' "$base/dl/Demo-Setup-1.2.0.exe" "http://localhost:$port/dl/SHA256SUMS.txt"   # same server, other host name
    Write-Release 'Redir' "$base/dl/Demo-Setup-1.2.0.exe" "$base/dl/redir"   # http.server: 301 -> /dl/redir/ (index.html)
    Write-Release 'Hop' "$base/dl/Demo-Setup-1.2.0.exe" "http://127.0.0.1:$hop/sums"   # 302 -> localhost: must be refused
    $null = New-Item -ItemType Directory -Force -Path "$srv\dl\redir"
    Write-Utf8 "$srv\dl\redir\index.html" ("{0}  Redir-Setup-1.2.0.exe`n" -f $hash)
    Write-Utf8 "$work\redir.py" ("import http.server, sys`n" +
        "class H(http.server.BaseHTTPRequestHandler):`n" +
        "    def do_GET(s): s.send_response(302); s.send_header('Location', sys.argv[2]); s.end_headers()`n" +
        "http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()`n")
    $hopSrv = Start-Process -FilePath $python -ArgumentList @('-I', "$work\redir.py", "$hop", "http://localhost:$port/dl/SHA256SUMS.txt") `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput "$work\hop.out" -RedirectStandardError "$work\hop.err"
    $null = $own.Add($hopSrv)
    $server = Start-Process -FilePath $python -ArgumentList @('-I', '-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $srv) `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput "$work\srv.out" -RedirectStandardError "$work\srv.err"
    $null = $own.Add($server)
    $deadline = (Get-Date).AddSeconds(15)
    while ($true) {
        $c = New-Object Net.Sockets.TcpClient
        try { $c.Connect('127.0.0.1', $port); $c.Close(); break } catch { $c.Close() }
        if ($server.HasExited -or (Get-Date) -gt $deadline) { throw "fake server did not start: $(Get-Content "$work\srv.err" -Raw)" }
        Start-Sleep -Milliseconds 200
    }

    # ---- environment of everything below: no real updates, private TEMP / LOCALAPPDATA, marker dir
    Set-TestEnv 'MAKEKIT_NO_UPDATE' '1'
    Set-TestEnv 'MAKEKIT_UPDATE_API' $null
    Set-TestEnv 'TEMP' $tmp
    Set-TestEnv 'TMP' $tmp
    Set-TestEnv 'LOCALAPPDATA' $lad
    Set-TestEnv 'MAKEUPDATE_E2E_DIR' $marks

    Write-Host 'check:'
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Demo', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 0 -and $r.J.ok -and $r.J.newer) "1.0.0 -> newer ($($r.Raw))"
    Check ($r.J.latest -eq '1.2.0' -and $r.J.tag -eq 'v1.2.0' -and $r.J.notes -eq 'Fixes') 'latest, tag, notes'
    Check ($r.J.sha256 -eq $hash.ToLower() -and $r.J.setup -eq "$base/dl/Demo-Setup-1.2.0.exe") 'sha256 from SHA256SUMS.txt, setup url'
    Check ($r.J.page -eq "$base/MakeMD/Demo/releases/tag/v1.2.0") 'page'
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Demo', '--current', '1.2.0', '--api-base', $base)
    Check ($r.Code -eq 0 -and $r.J.ok -and -not $r.J.newer -and $r.J.setup -eq '') '1.2.0 -> not newer'
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Demo', '--current', '1.10.0', '--api-base', $base)
    Check ($r.J.ok -and -not $r.J.newer) '1.10.0 -> not newer (numeric compare)'
    Set-TestEnv 'MAKEKIT_UPDATE_API' $base
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Demo', '--current', '1.0.0')
    Check ($r.J.ok -and $r.J.newer) 'MAKEKIT_UPDATE_API overrides the API base'
    Set-TestEnv 'MAKEKIT_UPDATE_API' $null
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Demo', '--current', '1.0.0')
    Check ($r.Code -eq 1 -and -not $r.J.ok -and $r.J.detail -like '*MAKEKIT_NO_UPDATE*') "MAKEKIT_NO_UPDATE=1 refuses the real API ($($r.J.detail))"
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $dead = $l.LocalEndpoint.Port; $l.Stop()
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Demo', '--current', '1.0.0', '--api-base', "http://127.0.0.1:$dead")
    Check ($r.Code -eq 1 -and $r.J.detail -like 'no connection*') "offline -> ok:false ($($r.J.detail))"
    Check ($r.J.reason -eq 'offline' -and $r.J.error -eq 'No internet connection.') "offline -> plain text for the user ($($r.J.error))"
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Nope', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'HTTP 404*') "unknown repo -> HTTP 404 ($($r.J.detail))"
    Check ($r.J.reason -eq 'failed' -and $r.J.error -eq 'Could not check for updates. Try again later.') "server problem -> plain text ($($r.J.error))"
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/../x', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'bad --repo*') 'repo with path tricks rejected'
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/EvilSetup', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'refusing host evil.invalid*') "setup on a foreign host refused ($($r.J.detail))"
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/EvilSums', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'refusing host localhost*') "SHA256SUMS.txt on a foreign host refused ($($r.J.detail))"
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Redir', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 0 -and $r.J.sha256 -eq $hash.ToLower()) "same-host redirect followed ($($r.Raw))"
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Hop', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'refusing host localhost*') "redirect to a foreign host refused ($($r.J.detail))"
    $null = New-Item -ItemType Directory -Force -Path "$srv\repos\MakeMD\Trav\releases", "$srv\repos\MakeMD\Page\releases"
    Write-Utf8 "$srv\repos\MakeMD\Trav\releases\latest" ('{"tag_name":"v1.2.0-a/../../pwned","html_url":"' + $base + '/p","assets":[' +
        '{"name":"Trav-Setup-1.2.0-a/../../pwned.exe","browser_download_url":"' + $base + '/dl/Demo-Setup-1.2.0.exe"},' +
        '{"name":"SHA256SUMS.txt","browser_download_url":"' + $base + '/dl/SHA256SUMS.txt"}]}')
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Trav', '--current', '1.0.0', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'bad tag_name*') "tag_name with a path refused ($($r.J.detail))"
    Write-Utf8 "$srv\repos\MakeMD\Page\releases\latest" $rel.Replace("$base/MakeMD/Demo/releases/tag/v1.2.0", 'http://evil.invalid/p')
    $r = Invoke-Updater $updater @('check', '--repo', 'MakeMD/Page', '--current', '1.2.0', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'refusing host evil.invalid*') "release page on a foreign host refused ($($r.J.detail))"

    Write-Host 'install:'
    Copy-Item $updater "$app\MakeUpdate.exe"
    Copy-Item "$work\fake.exe" "$app\DemoApp.exe"
    $dummy = Start-Dummy 3
    Set-TestEnv 'MAKEUPDATE_E2E_PROBE' "$app\MakeUpdate.exe"
    $t0 = Get-Date
    $r = Invoke-Updater "$app\MakeUpdate.exe" @('install', '--repo', 'MakeMD/Demo', '--tag', 'v1.2.0', '--wait-pid', "$($dummy.Id)", '--relaunch', "$app\DemoApp.exe", '--api-base', $base)
    $secs = ((Get-Date) - $t0).TotalSeconds
    Check ($r.Code -eq 0 -and $r.J.ok) "install ok ($($r.Raw), $([math]::Round($secs, 1)) s)"
    Check $dummy.HasExited 'waited for --wait-pid to exit'
    $setupMark = "$marks\Demo-Setup-1.2.0.exe.txt"
    Check (Test-Path $setupMark) 'fake setup ran'
    Check ((Get-Item $setupMark).LastWriteTime -ge $dummy.ExitTime.AddMilliseconds(-50)) 'setup ran after the app exited'
    $lines = @((Get-Content $setupMark -Raw) -split "`n")
    Check (($lines[0..3] -join ' ') -eq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS') 'setup switches'
    Check ($lines[4] -eq 'probe:absent') "running MakeUpdate.exe was out of the way while the setup ran ($($lines[4]); log: $(Get-Content "$lad\MakeUpdate\update.log" -Tail 4))"
    Check (Wait-File "$marks\DemoApp.exe.txt") 'app relaunched'
    Check (@(Get-ChildItem $tmp -Filter 'MakeUpdate-*').Count -eq 0) 'temp download folder removed'
    Check ((Test-Path "$app\MakeUpdate.exe") -and -not (Test-Path "$app\MakeUpdate.exe.old")) 'MakeUpdate.exe moved aside for the setup and put back'
    $log = Get-Content "$lad\MakeUpdate\update.log" -Raw
    Write-Host $log
    Check ($log -like '*SHA-256 ok*' -and $log -like '*setup done*' -and $log -like '*relaunched*') 'update.log in LOCALAPPDATA\MakeUpdate'

    Set-TestEnv 'MAKEUPDATE_E2E_PROBE' $null

    Write-Host 'tampered asset:'
    Remove-Item "$marks\*"
    [IO.File]::AppendAllText("$srv\dl\Demo-Setup-1.2.0.exe", 'x')
    $dummy2 = Start-Dummy 20
    $r = Invoke-Updater "$app\MakeUpdate.exe" @('install', '--repo', 'MakeMD/Demo', '--tag', 'v1.2.0', '--wait-pid', "$($dummy2.Id)", '--relaunch', "$app\DemoApp.exe", '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'SHA-256 mismatch*') "sha mismatch -> exit 1 ($($r.J.detail))"
    Check ($r.J.reason -eq 'damaged' -and $r.J.error -like 'The downloaded file is damaged*') "damaged -> plain text ($($r.J.error))"
    Check (-not $dummy2.HasExited) 'did not wait for the app'
    Start-Sleep -Milliseconds 500
    Check (@(Get-ChildItem $marks).Count -eq 0) 'nothing run (no setup, app still running -> no relaunch)'
    Check (@(Get-ChildItem $tmp -Filter 'MakeUpdate-*').Count -eq 0) 'download removed'
    Stop-Process -Id $dummy2.Id -Force
    $dummy2.WaitForExit()
    $r = Invoke-Updater "$app\MakeUpdate.exe" @('install', '--repo', 'MakeMD/Demo', '--tag', 'v1.2.0', '--wait-pid', "$($dummy2.Id)", '--relaunch', "$app\DemoApp.exe", '--api-base', $base)
    Check ($r.Code -eq 1 -and -not (Test-Path $setupMark)) 'app already gone: still no setup'
    Check (Wait-File "$marks\DemoApp.exe.txt") '... but the app is started again'

    Write-Host 'portable:'
    Remove-Item "$marks\*"
    Write-Utf8 "$app\portable.dat" ''
    $r = Invoke-Updater "$app\MakeUpdate.exe" @('install', '--repo', 'MakeMD/Demo', '--tag', 'v1.2.0', '--wait-pid', '4294967294', '--relaunch', "$app\DemoApp.exe", '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'portable*' -and -not (Test-Path $setupMark)) 'portable copy never installs'
    Check ($r.J.reason -eq 'portable') 'portable -> reason portable'
    Remove-Item "$app\portable.dat"

    Write-Host 'other release than asked for:'
    Write-Utf8 "$srv\repos\MakeMD\Demo\releases\tags\v1.3.0" $rel   # answers v1.2.0
    $r = Invoke-Updater "$app\MakeUpdate.exe" @('install', '--repo', 'MakeMD/Demo', '--tag', 'v1.3.0', '--wait-pid', '4294967294', '--api-base', $base)
    Check ($r.Code -eq 1 -and $r.J.detail -like 'asked for v1.3.0*' -and -not (Test-Path $setupMark)) "served tag must equal --tag ($($r.J.detail))"

    if (-not $NoGui) {
        Write-Host 'demo banner (kit.update.Checker + banner over the automation pipe, DISPLAY1):'
        $gui = Start-AutoApp -Exe (Join-Path $root 'zig-out\bin\makekit-demo.exe') -Env @{ MAKEKIT_UPDATE_API = $base; MAKEKIT_NO_UPDATE = '0' }
        $null = $own.Add($gui.Process)
        try {
            $null = Wait-AutoItem $gui 'Update now##updNow' 20000
            Check ((Get-AutoText $gui '##updText') -eq 'Version 1.2.0 is available') 'banner text'
            foreach ($b in @('Release notes##updNotes', 'Later##updLater')) { $null = Wait-AutoItem $gui $b }
            Save-AutoScreenshot $gui "$work\banner.png" -Png
            Invoke-AutoClick $gui 'Later##updLater'
            $null = Invoke-AutoFrames $gui 2
            Check (-not (@(Get-AutoItems $gui) | Where-Object { $_.label -like '*##updNow' })) 'Later hides the banner'
            Check ((Get-AutoText $gui '##info') -eq 'update banner: later') 'banner returned .later'
            if ($env:MAKEUPDATE_E2E_KEEP_SHOT) { Copy-Item "$work\banner.png" $env:MAKEUPDATE_E2E_KEEP_SHOT }
        } finally { Stop-AutoApp $gui }
    }

    $ok = $true
} finally {
    foreach ($p in $own) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    if (Test-Path $work) { Write-Host "warning: could not remove $work" }
}
if ($ok) { Write-Host 'UPDATE-E2E OK' } else { exit 1 }
