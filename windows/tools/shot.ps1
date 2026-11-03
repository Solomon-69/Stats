# shot.ps1: start the built app in a test view, wait for its report, take a real screenshot of its window, stop it.
param([string]$Exe, [string]$Name, [string]$View, [string]$Out = "shots", [int]$Wait = 40)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System.Runtime.InteropServices;
public class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][Dpi]::SetProcessDPIAware()
New-Item -ItemType Directory -Force $Out | Out-Null
$report = Join-Path (Resolve-Path $Out) "$Name.json"
Remove-Item $report -ErrorAction SilentlyContinue
$env:STATS_TEST = $View
$env:STATS_TEST_OUT = $report
$p = Start-Process -FilePath $Exe -PassThru
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path $report) -and $sw.Elapsed.TotalSeconds -lt $Wait) { Start-Sleep -Milliseconds 500 }
Start-Sleep -Milliseconds 800
$ok = Test-Path $report
$full = Join-Path (Resolve-Path $Out) "$Name-full.png"
$b = [Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
$g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
if ($ok) {
  $j = Get-Content $report -Raw | ConvertFrom-Json
  $label = if ($View.StartsWith('settings')) { 'settings' } else { 'panel' }
  $r = $j.rects.$label
  $x = [Math]::Max(0, $r.x - $b.X); $y = [Math]::Max(0, $r.y - $b.Y)
  $w = [Math]::Min($r.w, $b.Width - $x); $h = [Math]::Min($r.h, $b.Height - $y)
  $crop = $bmp.Clone((New-Object Drawing.Rectangle $x, $y, $w, $h), $bmp.PixelFormat)
  $crop.Save((Join-Path (Resolve-Path $Out) "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
}
$bmp.Save($full, [Drawing.Imaging.ImageFormat]::Png)
if (-not $ok) { Get-Process | Where-Object { $_.ProcessName -match "Stats|msedgewebview2" } | Format-Table Id,ProcessName,MainWindowTitle | Out-String | Write-Host; Get-WinEvent -FilterHashtable @{LogName="Application";Level=2;StartTime=(Get-Date).AddMinutes(-3)} -MaxEvents 5 -ErrorAction SilentlyContinue | ForEach-Object { $_.Message.Substring(0,[Math]::Min(300,$_.Message.Length)) } | Write-Host }
taskkill /T /F /PID $p.Id 2>$null | Out-Null
Start-Sleep -Seconds 1
if (-not $ok) { Write-Host "::error::no report for $Name (exited=$($p.HasExited))"; if ($p.HasExited) { Write-Host "exit code $($p.ExitCode)" }; $cl = Join-Path $env:TEMP "stats-crash.log"; if (Test-Path $cl) { Write-Host "CRASH LOG:"; Get-Content $cl | Write-Host } }
if (-not $ok) { exit 1 }
Write-Host "shot $Name ok"
