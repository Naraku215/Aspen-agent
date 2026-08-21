<#
show-aspen-window.ps1 - 把 Aspen Plus 主窗口恢复到前台。

MCP（COM）拉起的 Aspen 实例 GUI 窗口默认隐藏：进程在、任务栏无窗，
用户"看不到 Aspen 打开"。本脚本用 user32 ShowWindowAsync(SW_RESTORE) +
SetForegroundWindow 把它拽出来。对模型只读，可反复执行。

Usage:
  .\show-aspen-window.ps1
  .\show-aspen-window.ps1 -TargetPid 5708   # 多实例时指定
#>
param([int]$TargetPid = 0)
$sig = @'
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
$t = Add-Type -MemberDefinition $sig -Name W32api -Namespace W -PassThru
# 多实例时取最新启动的（MCP 当前 COM 会话所连的实例），旧的往往是残留窗口
$cands = @(Get-Process -Name AspenPlus -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [System.IntPtr]::Zero } | Sort-Object StartTime -Descending)
foreach ($c in $cands) {
  Write-Host ("candidate PID {0} started {1}: {2}" -f $c.Id, $c.StartTime.ToString('HH:mm:ss'), $c.MainWindowTitle)
}
if ($cands.Count -eq 0) { Write-Host "no AspenPlus window found"; exit 1 }
$p = if ($TargetPid -ne 0) { @($cands | Where-Object { $_.Id -eq $TargetPid })[0] } else { $cands[0] }
if ($p -eq $null) { Write-Host "PID $TargetPid not found among candidates"; exit 1 }
[void]$t::ShowWindowAsync($p.MainWindowHandle, 9)   # SW_RESTORE
[void]$t::SetForegroundWindow($p.MainWindowHandle)
Write-Host ("restored PID {0}: {1}" -f $p.Id, $p.MainWindowTitle)
