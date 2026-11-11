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
    foreach ($l in @('All##all', 'Documents##c1', 'Name##name', 'Show dialog##msg', 'Options##tabOptions', 'About##tabAbout', 'Level##lvl')) {
        if (-not ($items | Where-Object { $_.label -like "*$l" })) { throw "item '$l' missing" }
    }
    function Check($cond, [string]$what) { if (-not $cond) { throw "check failed: $what" } }
    Check ((Get-AutoText $app '##dpi') -like 'DPI *') 'kit.ui.text is readable (Get-AutoText ##dpi)'
    Check ((Get-AutoText $app '##iconCount') -eq '39 icons') 'icon grid drawn (kit.icons)'

    # compact check/radio boxes: smaller than a frame and centred on a frame-high line (SameLine / AlignTextToFramePadding)
    foreach ($pair in @(@('Button##mBtn', 'Check##mChk'), @('Button##mBtn', 'Radio##mRadio0'), @('Level##lvl', 'Verbose log##verbose'))) {
        $f = Wait-AutoItem $app $pair[0]; $c = Wait-AutoItem $app $pair[1]
        Check (($c.y1 - $c.y0) -lt ($f.y1 - $f.y0) -and [math]::Abs(($c.y0 + $c.y1) - ($f.y0 + $f.y1)) -le 1) "$($pair[1]) compact and centred on $($pair[0])"
    }

    # tri-state: "All" starts mixed; unchecking a child keeps it mixed (unchecked from ImGui's view)
    Check (Wait-AutoItem $app 'All##all').mixed 'All##all is mixed'
    Check (-not (Wait-AutoItem $app 'Documents##c1').mixed) 'Documents##c1 is not mixed'
    Invoke-AutoClick $app 'Documents##c1'
    $doc = Wait-AutoItem $app 'Documents##c1'
    if ($doc.checked) { throw 'Documents should be unchecked after click' }
    Invoke-AutoClick $app 'Verbose log##verbose'
    Check (Wait-AutoItem $app '##verbose').checked 'kit.ui.checkbox toggles'

    # tabs (plain BeginTabItem): labels + selected; combo (plain BeginCombo): label + preview value
    Check (Wait-AutoItem $app 'Options##tabOptions').selected 'Options tab selected'
    Check ((Get-AutoText $app 'Level##lvl') -eq 'Normal') 'combo preview = Normal'
    Invoke-AutoClick $app 'Level##lvl'
    Invoke-AutoClick $app 'Ultra'
    $null = Invoke-AutoFrames $app 2
    Check ((Get-AutoText $app 'Level##lvl') -eq 'Ultra') 'combo preview = Ultra after picking it'
    Invoke-AutoClick $app 'About##tabAbout'
    $null = Wait-AutoItem $app '##about' 3000
    Check ((Get-AutoText $app '##about') -like 'MakeKit: *') 'About tab text'
    Check (-not (Wait-AutoItem $app 'Options##tabOptions').selected) 'Options tab no longer selected'
    Check (Wait-AutoItem $app 'About##tabAbout').selected 'About tab selected'
    Invoke-AutoClick $app 'Options##tabOptions'

    # selectable rows: selected state; click the Status column of a SpanAllColumns row (-At 85%)
    Check (Wait-AutoItem $app 'Browser cache').selected 'row 0 selected'
    Invoke-AutoClick $app 'Thumbnails' -At '85%'
    $null = Invoke-AutoFrames $app 2
    Check (Wait-AutoItem $app 'Thumbnails').selected 'row 2 selected after a click at 85%'
    Check (-not (Wait-AutoItem $app 'Browser cache').selected) 'row 0 deselected'

    # background job: progress strip labels ##status / ##percent / ##cancel while running
    Invoke-AutoClick $app '##job'
    $null = Wait-AutoItem $app '##cancel' 3000
    $st = Get-AutoText $app '##status'
    $pc = Get-AutoText $app '##percent'
    Write-Host "progress: '$st' '$pc'"
    Check ($st -like 'Processing item *') 'progress status text'
    Check ($pc -match '^\d+% \(\d+ of 120\)$') 'progress percent text'

    # text input with non-ASCII text (Ukrainian), verified through the input's value and the echo button
    Invoke-AutoClick $app 'Name##name'
    $text = 'Hello ' + [string][char]0x0407 + [char]0x0436 + [char]0x0430 + [char]0x043A
    Invoke-AutoType $app $text
    $null = Wait-AutoItem $app ("Echo: $text##echo") 3000
    Check ((Get-AutoText $app 'Name##name') -eq $text) 'input value readable'

    # modal message box: text item, ##msgButtonN buttons; Esc = last button
    Invoke-AutoClick $app 'Show dialog##msg'
    $null = Wait-AutoItem $app 'Delete##msgButton0' 3000
    Check ((Get-AutoText $app '##msgText') -like 'Delete 3 selected items?*') 'message box text readable'
    Invoke-AutoKey $app 'Escape'
    $null = Wait-AutoItem $app 'Dialog: Cancel##dlgres' 3000
    # plain button text resolves to the open modal's button even while the page has a same-text button
    Invoke-AutoClick $app 'Show dialog##msg'
    $null = Wait-AutoItem $app '##msgButton1' 3000
    Invoke-AutoClick $app 'Delete'
    $null = Wait-AutoItem $app 'Dialog: Delete##dlgres' 3000

    $done = Wait-AutoItem $app '##jobdone' 20000
    Write-Host "job: $($done.label)"
    if ($done.label -notlike 'Job finished*') { throw "job did not finish cleanly: $($done.label)" }
    $null = Wait-AutoLabel $app 'Job finished*' 3000

    $null = Invoke-AutoFrames $app 3
    $shot = Save-AutoScreenshot $app (Join-Path $root 'zig-out\carbon-demo.png') -Png
    $sig = [System.IO.File]::ReadAllBytes($shot)[0..3]
    Check ($sig[1] -eq 0x50 -and $sig[2] -eq 0x4E -and $sig[3] -eq 0x47) 'screenshot is a PNG'
    Write-Host "screenshot: $shot"

    # leave a text input active: under automation the caret must not keep the loop rendering
    Invoke-AutoClick $app 'Name##name'

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
