# measure.ps1: how much of the PC does Stats use? Counts the app and its web view helper processes together.
param([string]$Exe, [string]$Name, [string]$View = "", [int]$Warm = 15, [int]$Span = 40, [string]$Out = "shots")
New-Item -ItemType Directory -Force $Out | Out-Null
$env:STATS_TEST = $View
$p = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds $Warm
function Tree($id) { $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" | ForEach-Object { $_.ProcessId }; $id; foreach ($k in $kids) { Tree $k } }
function Snap { $ids = Tree $p.Id; $ps = $ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }; [pscustomobject]@{ n = @($ps).Count; mem = ($ps | Measure-Object WorkingSet64 -Sum).Sum; cpuS = ($ps | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum } }
$a = Snap; Start-Sleep -Seconds $Span; $b = Snap
$cores = [Environment]::ProcessorCount
$pct = [Math]::Round((($b.cpuS - $a.cpuS) / $Span / $cores) * 100, 2)
$res = [pscustomobject]@{ name = $Name; view = $View; cpuPercentOfPc = $pct; cpuPercentOfOneCore = [Math]::Round(($b.cpuS - $a.cpuS) / $Span * 100, 2); processes = $b.n; memoryMB = [Math]::Round($b.mem / 1MB, 1); cores = $cores; seconds = $Span }
$res | ConvertTo-Json | Set-Content (Join-Path $Out "measure-$Name.json")
Write-Host ($res | ConvertTo-Json -Compress)
taskkill /T /F /PID $p.Id | Out-Null
