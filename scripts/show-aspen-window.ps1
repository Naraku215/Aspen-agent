<#
show-aspen-window.ps1 - 把 Aspen Plus 主窗口恢复到前台。

MCP（COM）拉起的 Aspen 实例 GUI 窗口默认隐藏：进程在、任务栏无窗，
用户"看不到 Aspen 打开"。本脚本用 user32 ShowWindowAsync(SW_RESTORE) +
SetForegroundWindow 把它拽出来。对模型只读，可反复执行。

Usage:
  .\show-aspen-window.ps1
#>
$sig = @'
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
$t = Add-Type -MemberDefinition $sig -Name W32api -Namespace W -PassThru
$p = Get-Process -Name AspenPlus -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [System.IntPtr]::Zero } | Select-Object -First 1
if ($p -eq $null) { Write-Host "no AspenPlus window found"; exit 1 }
[void]$t::ShowWindowAsync($p.MainWindowHandle, 9)   # SW_RESTORE
[void]$t::SetForegroundWindow($p.MainWindowHandle)
Write-Host ("restored PID {0}: {1}" -f $p.Id, $p.MainWindowTitle)
