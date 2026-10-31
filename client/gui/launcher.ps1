<#
  Steam 啟動器（由 tools/build_client.ps1 編成 deadlock_zhtw_launcher.exe，無視窗）

  Steam 啟動選項：  "<資料夾>\deadlock_zhtw_launcher.exe" %command%
  動作：先在背景靜默更新繁中（最多等 60 秒，失敗也沒關係），再啟動遊戲並等它結束。
  這個檔案不使用 param()，遊戲參數（例如 -novid）才不會被 PowerShell 當成自己的參數。
#>
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }

function ConvertTo-QuotedArg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $s = $a -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

# 1) 更新（任何錯誤都不影響遊戲啟動）：呼叫同資料夾的 deadlock_zhtw_updater.exe -Quiet
$updater = Join-Path $dir 'deadlock_zhtw_updater.exe'
if (Test-Path -LiteralPath $updater) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $updater
        $psi.Arguments = '-Quiet'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch {} }
    } catch {}
}

# 2) 啟動遊戲（Steam 傳進來的是完整的遊戲指令），並等它結束，讓 Steam 照常追蹤遊玩狀態
if ($args.Count -ge 1) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$args[0]
    $rest = @()
    for ($i = 1; $i -lt $args.Count; $i++) { $rest += ConvertTo-QuotedArg ([string]$args[$i]) }
    $psi.Arguments = $rest -join ' '
    $psi.UseShellExecute = $false
    $g = [System.Diagnostics.Process]::Start($psi)
    if ($g) { $g.WaitForExit() }
}
