# MakeKit ImGui automation client for PowerShell 5.1 (pure ASCII source).
# Dot-source it:  . .\tools\imgui-auto.ps1
#   $app = Start-AutoApp -Exe .\zig-out\bin\makekit-demo.exe
#   Get-AutoItems $app | Format-Table label, window, checked, visible
#   Invoke-AutoClick $app 'Start job##job'; Wait-AutoItem $app '##jobdone' 15000
#   Stop-AutoApp $app
# Protocol: one text command per line over \\.\pipe\makekit-auto-<pid>, one JSON object per reply line
# (see src/automation.zig). Non-ASCII text: build it with [char] codes, e.g. [string][char]0x0407.

Set-StrictMode -Version 2

function Start-AutoApp {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Alias('Args')][string[]]$ArgumentList = @(),
        [hashtable]$Env = @{},
        [int]$TimeoutMs = 15000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Resolve-Path -LiteralPath $Exe).Path
    $psi.Arguments = (@($ArgumentList) | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = Split-Path -Parent $psi.FileName
    $psi.EnvironmentVariables['MAKEKIT_AUTOMATION'] = '1'
    $psi.EnvironmentVariables['MAKEKIT_DISPLAY'] = '\\.\DISPLAY1'
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)

    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', "makekit-auto-$($p.Id)", [System.IO.Pipes.PipeDirection]::InOut)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        try { $pipe.Connect(250); break } catch {
            if ($p.HasExited) { throw "app exited with code $($p.ExitCode) before the automation pipe opened" }
            if ((Get-Date) -gt $deadline) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw "automation pipe of pid $($p.Id) did not open within $TimeoutMs ms" }
        }
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $reader = New-Object System.IO.StreamReader($pipe, $utf8)
    $writer = New-Object System.IO.StreamWriter($pipe, $utf8)
    $writer.AutoFlush = $true
    $writer.NewLine = "`n"
    [pscustomobject]@{ Process = $p; Pipe = $pipe; Reader = $reader; Writer = $writer }
}

# Sends one command line, returns the parsed reply; throws on {"ok":false} or timeout.
function Invoke-AutoCommand {
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$Line, [int]$TimeoutMs = 30000)
    $App.Writer.WriteLine($Line)
    $task = $App.Reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) { throw "automation: no reply to '$Line' within $TimeoutMs ms" }
    $resp = $task.Result
    if ($null -eq $resp) { throw "automation: pipe closed (app exited?) after '$Line'" }
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.ok) { throw "automation: $($obj.error)" }
    $obj
}

# Items of the last rendered frame (id, label, window, x0..y1, visible, disabled, checkable, checked,
# openable, opened, inputable, edited). -Windows returns the window list instead.
function Get-AutoItems {
    param([Parameter(Mandatory = $true)]$App, [switch]$Windows)
    $r = Invoke-AutoCommand $App 'list'
    if ($Windows) { return @($r.windows) }
    @($r.items)
}

# Label match: exact full label, else a label ending with the given '##id', else substring.
function Invoke-AutoClick {
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$Label,
        [ValidateSet('click', 'dblclick', 'rclick', 'hover')][string]$Kind = 'click')
    $null = Invoke-AutoCommand $App "$Kind $Label"
}

# Types into the active (focused) text input; click the input first.
function Invoke-AutoType {
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$Text)
    $null = Invoke-AutoCommand $App "type $Text"
}

# ImGuiKey name with optional modifiers: 'Enter', 'Escape', 'ctrl+A', 'shift+Tab', 'F5'.
function Invoke-AutoKey {
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$Chord)
    $null = Invoke-AutoCommand $App "key $Chord"
}

# Waits until an item with the label exists; returns it.
function Wait-AutoItem {
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$Label, [int]$TimeoutMs = 5000)
    $r = Invoke-AutoCommand $App "wait $Label $TimeoutMs" -TimeoutMs ($TimeoutMs + 10000)
    $r.item
}

# Renders N frames, returns the frame counter.
function Invoke-AutoFrames {
    param([Parameter(Mandatory = $true)]$App, [int]$Count = 1)
    (Invoke-AutoCommand $App "frames $Count").frame
}

# Saves the window's back buffer as a 32-bit BMP.
function Save-AutoScreenshot {
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $null = Invoke-AutoCommand $App "screenshot $full"
    $full
}

# Asks the app to quit; kills it (by PID) if it does not exit in time.
function Stop-AutoApp {
    param([Parameter(Mandatory = $true)]$App, [int]$TimeoutMs = 5000)
    try { $null = Invoke-AutoCommand $App 'quit' -TimeoutMs $TimeoutMs } catch { }
    if (-not $App.Process.WaitForExit($TimeoutMs)) { Stop-Process -Id $App.Process.Id -Force -ErrorAction SilentlyContinue }
    try { $App.Pipe.Dispose() } catch { }
    $App.Process.ExitCode
}
