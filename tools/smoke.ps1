# MakeKit smoke test (PowerShell 5.1, pure ASCII): builds the demo, drives it over the automation
# pipe on \\.\DISPLAY1, checks idle CPU, prints SMOKE OK.
#   powershell -ExecutionPolicy Bypass -File tools\smoke.ps1 [-Optimize ReleaseSafe]
param([string]$Optimize = 'Debug')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'imgui-auto.ps1')

$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
if (-not (Test-Path $zig)) { $zig = 'zig' }
Push-Location $root
try {
    & $zig build demo "-Doptimize=$Optimize"
    if ($LASTEXITCODE -ne 0) { throw "zig build demo failed ($LASTEXITCODE)" }
} finally { Pop-Location }

$exe = Join-Path $root 'zig-out\bin\makekit-demo.exe'
$app = Start-AutoApp -Exe $exe
$ok = $false
try {
    $items = @(Get-AutoItems $app)   # @() : a single result is not an array in PS 5.1
    Write-Host ("items in frame: {0}, windows: {1}" -f $items.Count, @(Get-AutoItems $app -Windows).Count)
    foreach ($l in @('All##all', 'Documents##c1', 'Name##name', 'Show dialog##msg')) {
        if (-not ($items | Where-Object { $_.label -like "*$l" })) { throw "item '$l' missing" }
    }

    # tri-state: unchecking a child makes "All" mixed (unchecked from ImGui's view)
    Invoke-AutoClick $app 'Documents##c1'
    $doc = Wait-AutoItem $app 'Documents##c1'
    if ($doc.checked) { throw 'Documents should be unchecked after click' }

    # background job (progress strip + Cancel button while running)
    Invoke-AutoClick $app '##job'
    $null = Wait-AutoItem $app 'Cancel##job' 3000

    # text input with non-ASCII text (Ukrainian), verified through the echo button label
    Invoke-AutoClick $app 'Name##name'
    $text = 'Hello ' + [string][char]0x0407 + [char]0x0436 + [char]0x0430 + [char]0x043A
    Invoke-AutoType $app $text
    $null = Wait-AutoItem $app ("Echo: $text##echo") 3000

    # modal message box: Esc = last button
    Invoke-AutoClick $app 'Show dialog##msg'
    $null = Wait-AutoItem $app 'Delete' 3000
    Invoke-AutoKey $app 'Escape'
    $null = Wait-AutoItem $app 'Dialog: Cancel##dlgres' 3000

    $done = Wait-AutoItem $app '##jobdone' 20000
    Write-Host "job: $($done.label)"
    if ($done.label -notlike 'Job finished*') { throw "job did not finish cleanly: $($done.label)" }

    $null = Invoke-AutoFrames $app 3
    $shot = Save-AutoScreenshot $app (Join-Path $root 'zig-out\smoke.bmp')
    Write-Host "screenshot: $shot"

    # idle CPU: let the post-input frame tail (1.5 s) settle, then measure 10 s
    Start-Sleep -Milliseconds 2500
    $p = $app.Process
    $p.Refresh(); $c0 = $p.TotalProcessorTime; $t0 = Get-Date
    Start-Sleep -Seconds 10
    $p.Refresh(); $c1 = $p.TotalProcessorTime; $secs = ((Get-Date) - $t0).TotalSeconds
    $pct = ($c1 - $c0).TotalSeconds / $secs * 100
    Write-Host ("idle CPU: {0:N3}% of one core over {1:N1} s" -f $pct, $secs)
    if ($pct -ge 1.0) { throw "idle CPU too high: $pct%" }
    $ok = $true
} finally {
    $code = Stop-AutoApp $app
    Write-Host "app exit code: $code"
}
if ($ok) { Write-Host 'SMOKE OK' } else { exit 1 }
