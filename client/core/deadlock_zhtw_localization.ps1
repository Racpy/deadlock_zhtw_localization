<#
  Deadlock 繁體中文更新器（核心）

  這一份腳本同時是兩種版本的核心：
    GUI 版    編成 deadlock_zhtw_updater.exe，雙擊開啟視窗；Steam 用 deadlock_zhtw_launcher.exe 呼叫它的 -Quiet
    NoGUI 版  直接用 setup.bat / launch.bat / restore.bat 呼叫

  參數：
    -Setup      首次設定：偵測遊戲、更新一次、產生 Steam 啟動選項
    -Restore    還原成安裝前的狀態（取代的檔案還原、gameinfo.gi / fonts.conf 的補丁移除）
    -CheckOnly  只檢查哪些檔案需要更新，不寫入
    -Quiet      不顯示訊息（啟動遊戲時使用），只寫入 data\update.log
    -Gui        開啟圖形介面（編成 exe 後雙擊就是這個模式）

  離線、網路失敗、GitHub 掛掉時，只會記錄到 data\update.log，不會阻擋遊戲啟動。
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Restore,
    [switch]$CheckOnly,
    [switch]$Quiet,
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# 編成 exe（ps2exe）後 $PSScriptRoot 是空的，改用 exe 所在資料夾
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
# 編成 exe 後沒有帶任何參數（雙擊）就直接開圖形介面
if (-not $PSScriptRoot -and -not ($Setup -or $Restore -or $CheckOnly -or $Quiet)) { $Gui = [switch]$true }
# 執行時產生的檔案（記錄、備份、設定、版本）全部放在 data 資料夾，不弄亂程式所在的資料夾
$DataDir      = Join-Path $ScriptDir 'data'
$LogFile      = Join-Path $DataDir 'update.log'
$StateFile    = Join-Path $DataDir 'state.json'
$SettingsFile = Join-Path $DataDir 'settings.json'
$BackupDir    = Join-Path $DataDir 'backup'
$Clock     = [Diagnostics.Stopwatch]::StartNew()

# GUI 模式會設定這些；命令列 / launch.bat 模式下維持 $null，行為與以前完全相同
$script:GuiMode      = $false
$script:LogSink      = $null     # scriptblock($message, $level)
$script:ProgressSink = $null     # scriptblock($done, $total)
$script:TotalLimit   = $null     # 覆寫 maxTotalSec（GUI 不需要 30 秒的限制）
$script:LastResult   = $null     # Invoke-Update 的結果，給 GUI 顯示
$script:PatchPending = 0         # CheckOnly 時，還需要補丁的檔案數

# ---------------------------------------------------------------- 記錄
function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null } } catch {}
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:LogSink) { try { & $script:LogSink $Message $Level } catch {} }
    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $Message -ForegroundColor Red }
            'WARN'  { Write-Host $Message -ForegroundColor Yellow }
            default { Write-Host $Message }
        }
    }
}

function Limit-LogSize {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 200KB)) {
            $tail = Get-Content -LiteralPath $LogFile -Tail 500 -Encoding UTF8
            Set-Content -LiteralPath $LogFile -Value $tail -Encoding UTF8
        }
    } catch {}
}

# ---------------------------------------------------------------- 設定
# 內建設定。更新來源與路徑白名單固定在這裡，不開放使用者修改
# （白名單需與 tools/make_manifest.py 的 DEFAULT_PREFIXES / DEFAULT_EXT 保持一致）。
# 使用者只能調整 $UserSettingKeys 列出的三項，存在 data\settings.json（圖形介面會自動處理）。
$Defaults = [ordered]@{
    repoOwner         = 'Racpy'
    repoName          = 'deadlock_zhtw_localization'
    branch            = 'main'
    appId             = 1422450
    timeoutSec        = 8
    maxTotalSec       = 30
    maxFileSizeMB     = 20
    allowedPrefixes   = @('game/citadel/', 'game/citadel_tchinese/')
    allowedExtensions = @('.txt', '.vpk', '.gi', '.conf')
    gamePath          = ''
    patchGameInfo     = $true
    patchFonts        = $true
}
$UserSettingKeys = 'gamePath', 'patchGameInfo', 'patchFonts'

function Get-Config {
    $c = [pscustomobject]$Defaults
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $u = [IO.File]::ReadAllText($SettingsFile, $Utf8NoBom).TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($k in $UserSettingKeys) {
                $v = $u.$k
                if ($null -eq $v) { continue }
                if ($k -eq 'gamePath' -and $v -is [string]) { $c.$k = $v }
                elseif ($k -ne 'gamePath' -and $v -is [bool]) { $c.$k = $v }
            }
        } catch { Write-Log "settings.json 讀取失敗，使用預設值：$($_.Exception.Message)" 'WARN' }
    }
    return $c
}

# ---------------------------------------------------------------- 找遊戲
function Get-SteamPath {
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            $v = if ($p.SteamPath) { $p.SteamPath } elseif ($p.InstallPath) { $p.InstallPath } else { $null }
            if ($v) {
                $v = $v -replace '/', '\'
                if (Test-Path -LiteralPath $v) { return $v }
            }
        } catch {}
    }
    return $null
}

function Find-GameDir($Config) {
    # 1) 使用者手動指定
    if ($Config.gamePath) {
        if (Test-Path -LiteralPath $Config.gamePath) { return (Resolve-Path -LiteralPath $Config.gamePath).Path }
        Write-Log "已儲存的遊戲路徑不存在：$($Config.gamePath)" 'WARN'
    }

    # 2) 從 Steam 資料庫找 appmanifest_<appId>.acf
    $steam = Get-SteamPath
    if (-not $steam) { return $null }

    $libs = New-Object 'System.Collections.Generic.List[string]'
    $libs.Add($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = [IO.File]::ReadAllText($vdf)
        foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
            $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
        }
    }

    foreach ($lib in ($libs | Select-Object -Unique)) {
        $acf = Join-Path $lib ("steamapps\appmanifest_{0}.acf" -f $Config.appId)
        if (-not (Test-Path -LiteralPath $acf)) { continue }
        $content = [IO.File]::ReadAllText($acf)
        if ($content -match '"installdir"\s+"([^"]+)"') {
            $dir = Join-Path $lib ("steamapps\common\" + $Matches[1])
            if (Test-Path -LiteralPath $dir) { return $dir }
        }
    }
    return $null
}

# ---------------------------------------------------------------- 安全：目標路徑檢查
function Resolve-TargetPath([string]$GameDir, [string]$Rel, $Config) {
    if ([string]::IsNullOrWhiteSpace($Rel)) { throw '路徑是空的' }
    if ($Rel -match '(^|[\\/])\.\.([\\/]|$)' -or $Rel.Contains(':') -or $Rel.StartsWith('/') -or $Rel.StartsWith('\')) {
        throw "不安全的路徑：$Rel"
    }
    $relWin = $Rel -replace '/', '\'

    $okPrefix = $false
    foreach ($p in $Config.allowedPrefixes) {
        $pw = ($p -replace '/', '\').TrimEnd('\') + '\'
        if ($relWin.StartsWith($pw, [StringComparison]::OrdinalIgnoreCase)) { $okPrefix = $true; break }
    }
    if (-not $okPrefix) { throw "不在允許的目錄內：$Rel" }

    $ext = [IO.Path]::GetExtension($relWin).ToLowerInvariant()
    if (-not ($Config.allowedExtensions | Where-Object { $_.ToLowerInvariant() -eq $ext })) {
        throw "不允許的副檔名：$Rel"
    }

    $full = [IO.Path]::GetFullPath((Join-Path $GameDir $relWin))
    $root = [IO.Path]::GetFullPath($GameDir).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "路徑跑出遊戲目錄：$Rel" }
    return $full
}

# ---------------------------------------------------------------- 網路 / 雜湊
Add-Type -AssemblyName System.Net.Http
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Get-RemoteBytes([string]$Url, $Config) {
    $client = New-Object System.Net.Http.HttpClient
    try {
        $client.Timeout = [TimeSpan]::FromSeconds([int]$Config.timeoutSec)
        [void]$client.DefaultRequestHeaders.UserAgent.ParseAdd('deadlock_zhtw_localization-Updater/1.0')
        $cc = New-Object System.Net.Http.Headers.CacheControlHeaderValue
        $cc.NoCache = $true
        $client.DefaultRequestHeaders.CacheControl = $cc
        if ($script:GuiMode) {
            # 非同步等待，等的時候讓視窗繼續回應（不會「沒有回應」）
            $task = $client.GetByteArrayAsync($Url)
            while (-not $task.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 15
            }
            $bytes = $task.GetAwaiter().GetResult()
        } else {
            $bytes = $client.GetByteArrayAsync($Url).GetAwaiter().GetResult()
        }
        return , $bytes
    } finally { $client.Dispose() }
}

function ConvertTo-Hex([byte[]]$Hash) { ($Hash | ForEach-Object { $_.ToString('x2') }) -join '' }

function Get-Sha256OfBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ConvertTo-Hex ($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}

function Get-Sha256OfFile([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { return ConvertTo-Hex ($sha.ComputeHash($fs)) } finally { $fs.Dispose(); $sha.Dispose() }
}

function ConvertTo-UrlPath([string]$Rel) {
    (($Rel -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
}

# ---------------------------------------------------------------- 備份
function Save-Backup([string]$GameDir, [string]$Rel, [string]$Dest) {
    $relWin = $Rel -replace '/', '\'
    $origin = Join-Path (Join-Path $BackupDir 'original') $relWin
    $absent = "$origin.absent"
    $prev   = Join-Path (Join-Path $BackupDir 'previous') $relWin

    if (Test-Path -LiteralPath $Dest) {
        # 第一次覆寫前，保留最原始的版本（只存一次）
        if (-not (Test-Path -LiteralPath $origin) -and -not (Test-Path -LiteralPath $absent)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $origin) | Out-Null
            Copy-Item -LiteralPath $Dest -Destination $origin -Force
        }
        # 每次更新前的上一版
        New-Item -ItemType Directory -Force -Path (Split-Path $prev) | Out-Null
        Copy-Item -LiteralPath $Dest -Destination $prev -Force
    } else {
        # 原本不存在的檔案：做個標記，還原時改為刪除
        if (-not (Test-Path -LiteralPath $origin) -and -not (Test-Path -LiteralPath $absent)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $absent) | Out-Null
            Set-Content -LiteralPath $absent -Value 'absent before install' -Encoding ASCII
        }
    }
}

# ---------------------------------------------------------------- gameinfo.gi 補丁
# game/citadel/gameinfo.gi 是 Valve 的檔案，每次遊戲更新都可能變動，所以不整檔取代，
# 只確保 SupportedLanguages 區段內有 "tchinese" "3" 這一行，其餘內容一律保持 Valve 的最新版。
$GameInfoRel   = 'game/citadel/gameinfo.gi'
$PatchFlagFile = Join-Path $BackupDir 'gameinfo_patched.flag'   # 只有「我們加的」才會有這個標記
$PatchLine     = '"tchinese" "3"'
$LangBlockRe   = '(?s)(SupportedLanguages\s*\{)(.*?)(\})'
$HasTchineseRe = '(?im)^[ \t]*"tchinese"[ \t]+"'
$LastIndentRe  = '(?m)^([ \t]+)"'
$TrailRe       = '\s*$'
$RemoveLineRe  = '(?im)^[ \t]*"tchinese"[ \t]+"[^"]*"[ \t]*(\r?\n|$)'
$Utf8NoBom     = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8Text([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text  = $Utf8NoBom.GetString($bytes)
    # 含有非 UTF-8 內容的檔案，轉成文字再轉回來會不一樣，這種檔案不碰
    if ((Get-Sha256OfBytes ($Utf8NoBom.GetBytes($text))) -ne (Get-Sha256OfBytes $bytes)) {
        throw '檔案不是標準 UTF-8 文字檔，已略過'
    }
    return $text
}

function Write-TextAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.zhtw.tmp"
    try {
        [IO.File]::WriteAllBytes($tmp, $Utf8NoBom.GetBytes($Text))
        if (Test-Path -LiteralPath $Path) { Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $false }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# 回傳：補丁後的文字；已經有 tchinese 時回傳原文；找不到區段時回傳 $null
function Add-TchineseToText([string]$Text) {
    $m = [regex]::Match($Text, $LangBlockRe)
    if (-not $m.Success) { return $null }
    $g = $m.Groups[2]
    if ([regex]::IsMatch($g.Value, $HasTchineseRe)) { return $Text }

    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $indents = [regex]::Matches($g.Value, $LastIndentRe)
    $indent  = if ($indents.Count -gt 0) { $indents[$indents.Count - 1].Groups[1].Value } else { "`t`t" }
    $trail   = [regex]::Match($g.Value, $TrailRe).Value
    $body    = $g.Value.Substring(0, $g.Value.Length - $trail.Length)

    return $Text.Substring(0, $g.Index) + $body + $nl + $indent + $PatchLine + $trail + $Text.Substring($g.Index + $g.Length)
}

function Remove-TchineseFromText([string]$Text) {
    $m = [regex]::Match($Text, $LangBlockRe)
    if (-not $m.Success) { return $Text }
    $g = $m.Groups[2]
    $new = [regex]::Replace($g.Value, $RemoveLineRe, '')
    return $Text.Substring(0, $g.Index) + $new + $Text.Substring($g.Index + $g.Length)
}

function Update-GameInfo([string]$GameDir, $Config) {
    if (-not $Config.patchGameInfo) { return }
    try {
        $path = Resolve-TargetPath $GameDir $GameInfoRel $Config
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "找不到 $GameInfoRel，略過語言補丁" 'WARN'
            return
        }
        $text = Read-Utf8Text $path
        $new  = Add-TchineseToText $text
        if ($null -eq $new) {
            Write-Log "$GameInfoRel 找不到 SupportedLanguages 區段（Valve 可能改了格式），已略過語言補丁" 'WARN'
            return
        }
        if ($new -ceq $text) { return }   # 已經有 tchinese，不需要動

        if ($CheckOnly) { $script:PatchPending++; Write-Log "需要補丁：$GameInfoRel（加入 tchinese 語言）"; return }

        $prev = Join-Path (Join-Path $BackupDir 'previous') ($GameInfoRel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path $prev) | Out-Null
        Copy-Item -LiteralPath $path -Destination $prev -Force

        Write-TextAtomic $path $new
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        Set-Content -LiteralPath $PatchFlagFile -Value 'patched by deadlock_zhtw_localization' -Encoding ASCII
        Write-Log "已補丁：$GameInfoRel（加入 tchinese 語言）"
    } catch {
        Write-Log "gameinfo.gi 補丁失敗：$($_.Exception.Message)" 'ERROR'
    }
}

function Undo-GameInfoPatch([string]$GameDir, $Config) {
    # 只有「補丁是我們加的」才移除，避免誤刪 Valve 之後自己加入的 tchinese
    if (-not (Test-Path -LiteralPath $PatchFlagFile)) { return }
    try {
        $path = Resolve-TargetPath $GameDir $GameInfoRel $Config
        if (Test-Path -LiteralPath $path) {
            $text = Read-Utf8Text $path
            $new  = Remove-TchineseFromText $text
            if ($new -cne $text) {
                Write-TextAtomic $path $new
                Write-Log "已還原：$GameInfoRel（移除 tchinese 語言）"
            }
        }
        Remove-Item -LiteralPath $PatchFlagFile -Force
    } catch {
        Write-Log "還原 gameinfo.gi 失敗：$($_.Exception.Message)" 'ERROR'
    }
}

# ---------------------------------------------------------------- fonts.conf 補丁
# game/citadel/panorama/fonts/fonts.conf 同樣是 Valve 的檔案，所以也用補丁而不是整檔取代：
# 把下面的 zh-tw 字型規則，用 BEGIN/END 標記註解包起來，插在 Valve 的指定註解之前
# （位置不能亂放：fontconfig 依規則順序比對，必須在 Gulim/MingLiu 轉換規則之前）。
# 要改規則：直接修改 $FontsBlockBody，下次啟動時會自動替換玩家那邊已套用的舊規則。
$FontsRel      = 'game/citadel/panorama/fonts/fonts.conf'
$FontsBegin    = "`t<!-- BEGIN deadlock_zhtw_localization (auto-generated, do not edit) -->"
$FontsEnd      = "`t<!-- END deadlock_zhtw_localization -->"
$FontsAnchorRe = '(?m)^[ \t]*<!--[ \t]*Use English font globally for elements using the numeric font families[ \t]*-->'
$FontsBlockRe  = '(?s)[ \t]*<!-- BEGIN deadlock_zhtw_localization[^\r\n]*-->.*?<!-- END deadlock_zhtw_localization -->'
$FontsBlockBody = @'
	<match>
		<test name="lang">
			<string>zh-tw</string>
		</test>
		<test name="family" compare="contains">
			<string>VALVEPulp</string>
		</test>
		<edit name="family" mode="assign" binding="strong">
			<string>Noto Sans TC</string>
		</edit>
		<edit name="weight" mode="assign" binding="strong">
			<const>bold</const>
		</edit>
	</match>
	<!-- Use Noto Sans for TC characters, but not for numbers and symbols -->
	<match>
		<test name="family">
			<string>Reaver</string>
		</test>
		<test name="lang">
			<string>zh-tw</string>
		</test>
		<edit name="family" mode="append_last" binding="strong">
			<string>Noto Sans TC</string>
		</edit>
	</match>
	<!-- Use Noto Sans for TC characters, but not for numbers and symbols -->
	<match>
		<test name="family">
			<string>Retail Demo</string>
		</test>
		<test name="lang">
			<string>zh-tw</string>
		</test>
		<edit name="family" mode="append_last" binding="strong">
			<string>Noto Sans TC</string>
		</edit>
	</match>
'@

function Get-FontsDesiredBlock([string]$Nl) {
    $body = $FontsBlockBody -replace '\r?\n', $Nl
    return $FontsBegin + $Nl + $body + $Nl + $FontsEnd
}

function Test-XmlWellFormed([string]$Text) {
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $sr = New-Object System.IO.StringReader -ArgumentList $Text.TrimStart([char]0xFEFF)
        $reader = [System.Xml.XmlReader]::Create($sr, $settings)
        try { while ($reader.Read()) { } } finally { $reader.Dispose(); $sr.Dispose() }
        return $true
    } catch { return $false }
}

# 回傳：新文字；內容已是最新時回傳原文；找不到插入位置時回傳 $null
function Add-FontsBlockToText([string]$Text) {
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $want = Get-FontsDesiredBlock $nl

    # 1) 已有我們的區塊：相同就不動，不同（規則有更新）就替換
    $m = [regex]::Match($Text, $FontsBlockRe)
    if ($m.Success) {
        if ($m.Value -ceq $want) { return $Text }
        return $Text.Substring(0, $m.Index) + $want + $Text.Substring($m.Index + $m.Length)
    }

    # 2) 插在 Valve 註解那一行之前
    $a = [regex]::Match($Text, $FontsAnchorRe)
    if (-not $a.Success) { return $null }
    return $Text.Insert($a.Index, $want + $nl + $nl)
}

function Remove-FontsBlockFromText([string]$Text) {
    return [regex]::Replace($Text, $FontsBlockRe + '(?:\r?\n){0,2}', '')
}

function Update-FontsConf([string]$GameDir, $Config) {
    if (-not $Config.patchFonts) { return }
    try {
        $path = Resolve-TargetPath $GameDir $FontsRel $Config
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "找不到 $FontsRel，略過字型補丁" 'WARN'
            return
        }
        $text = Read-Utf8Text $path
        $new  = Add-FontsBlockToText $text
        if ($null -eq $new) {
            Write-Log "$FontsRel 找不到插入位置（Valve 可能改了格式），已略過字型補丁" 'WARN'
            return
        }
        if ($new -ceq $text) { return }   # 已是最新

        # 寫入前先確認結果是合法的 XML，否則寧可不動，避免遊戲讀不到字型設定
        if (-not (Test-XmlWellFormed $new)) {
            Write-Log "$FontsRel 補丁後 XML 格式不正確，已取消字型補丁" 'ERROR'
            return
        }
        if ($CheckOnly) { $script:PatchPending++; Write-Log "需要補丁：$FontsRel（zh-tw 字型規則）"; return }

        $prev = Join-Path (Join-Path $BackupDir 'previous') ($FontsRel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path $prev) | Out-Null
        Copy-Item -LiteralPath $path -Destination $prev -Force

        Write-TextAtomic $path $new
        Write-Log "已補丁：$FontsRel（zh-tw 字型規則）"
    } catch {
        Write-Log "fonts.conf 補丁失敗：$($_.Exception.Message)" 'ERROR'
    }
}

function Undo-FontsPatch([string]$GameDir, $Config) {
    # 用標記註解判斷是不是我們加的，不需要額外的記號檔
    try {
        $path = Resolve-TargetPath $GameDir $FontsRel $Config
        if (-not (Test-Path -LiteralPath $path)) { return }
        $text = Read-Utf8Text $path
        $new  = Remove-FontsBlockFromText $text
        if ($new -cne $text) {
            Write-TextAtomic $path $new
            Write-Log "已還原：$FontsRel（移除 zh-tw 字型規則）"
        }
    } catch {
        Write-Log "還原 fonts.conf 失敗：$($_.Exception.Message)" 'ERROR'
    }
}

# ---------------------------------------------------------------- 狀態（給 GUI 顯示「目前版本」）
function Save-State([string]$Version) {
    try {
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        $o = @{ version = $Version; updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json
        [IO.File]::WriteAllText($StateFile, $o, $Utf8NoBom)
    } catch {}
}

function Get-State {
    try {
        if (Test-Path -LiteralPath $StateFile) {
            return ([IO.File]::ReadAllText($StateFile, $Utf8NoBom) | ConvertFrom-Json)
        }
    } catch {}
    return $null
}

# ---------------------------------------------------------------- 更新
function Invoke-Update($Config, [string]$GameDir) {
    $base = 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $Config.repoOwner, $Config.repoName, $Config.branch
    $nocache = [DateTime]::UtcNow.Ticks

    Write-Log "遊戲目錄：$GameDir"
    try {
        $mBytes = Get-RemoteBytes "$base/manifest.json?t=$nocache" $Config
    } catch {
        Write-Log "無法取得 manifest（可能離線或 GitHub 無法連線）：$($_.Exception.Message)" 'WARN'
        return 3
    }

    $manifest = ([Text.Encoding]::UTF8.GetString($mBytes)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or -not $manifest.files) {
        Write-Log 'manifest 格式不符（可能需要更新本程式）' 'ERROR'
        return 1
    }

    $same = 0; $updated = 0; $failed = 0
    $limit = if ($script:TotalLimit) { [int]$script:TotalLimit } else { [int]$Config.maxTotalSec }
    $total = @($manifest.files).Count; $done = 0
    foreach ($f in $manifest.files) {
        if ($script:ProgressSink) { & $script:ProgressSink $done $total }
        $done++
        if ($Clock.Elapsed.TotalSeconds -gt $limit) {
            Write-Log "已超過 $limit 秒，停止本次更新（下次啟動再試）" 'WARN'
            $failed++
            break
        }
        $tmp = $null
        try {
            $dest = Resolve-TargetPath $GameDir $f.path $Config
            $want = ([string]$f.sha256).ToLowerInvariant()
            if ($want -notmatch '^[0-9a-f]{64}$') { throw 'manifest 內的 sha256 格式不正確' }
            if ([int64]$f.size -gt ([int64]$Config.maxFileSizeMB * 1MB)) { throw '檔案超過大小上限' }

            if ((Test-Path -LiteralPath $dest) -and ((Get-Sha256OfFile $dest) -eq $want)) { $same++; continue }

            if ($CheckOnly) { Write-Log "需要更新：$($f.path)"; $updated++; continue }

            $bytes = Get-RemoteBytes ("$base/files/" + (ConvertTo-UrlPath $f.path) + "?t=$nocache") $Config
            if ((Get-Sha256OfBytes $bytes) -ne $want) { throw '下載內容的 SHA256 與 manifest 不符，已捨棄' }

            Save-Backup $GameDir $f.path $dest
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            if (Test-Path -LiteralPath $dest) { Set-ItemProperty -LiteralPath $dest -Name IsReadOnly -Value $false }

            $tmp = "$dest.zhtw.tmp"
            [IO.File]::WriteAllBytes($tmp, $bytes)
            Move-Item -LiteralPath $tmp -Destination $dest -Force

            Write-Log "已更新：$($f.path)"
            $updated++
        } catch {
            Write-Log "失敗：$($f.path) — $($_.Exception.Message)" 'ERROR'
            if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            $failed++
        }
    }

    if ($script:ProgressSink) { & $script:ProgressSink $total $total }
    $script:LastResult = @{ Version = [string]$manifest.version; Updated = $updated; Same = $same; Failed = $failed; Total = $total }
    if (-not $CheckOnly -and $failed -eq 0) { Save-State ([string]$manifest.version) }
    Write-Log ("完成：版本 {0}，更新 {1}、已是最新 {2}、失敗 {3}" -f $manifest.version, $updated, $same, $failed)
    if ($failed -gt 0) { return 1 } else { return 0 }
}

# ---------------------------------------------------------------- 還原
function Invoke-Restore([string]$GameDir, $Config) {
    Undo-GameInfoPatch $GameDir $Config
    Undo-FontsPatch $GameDir $Config
    $origRoot = Join-Path $BackupDir 'original'
    if (-not (Test-Path -LiteralPath $origRoot)) {
        Write-Log '找不到備份，沒有可還原的內容。' 'WARN'
        return 1
    }
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $origRoot -Recurse -File) {
        $relWin = $file.FullName.Substring($origRoot.Length).TrimStart('\')
        $isAbsent = $relWin.EndsWith('.absent')
        if ($isAbsent) { $relWin = $relWin.Substring(0, $relWin.Length - '.absent'.Length) }
        try {
            $dest = Resolve-TargetPath $GameDir ($relWin -replace '\\', '/') $Config
            if ($isAbsent) {
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
                Write-Log "已移除（安裝前不存在）：$relWin"
            } else {
                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
                Write-Log "已還原：$relWin"
            }
            $count++
        } catch {
            Write-Log "還原失敗：$relWin — $($_.Exception.Message)" 'ERROR'
        }
    }
    Write-Log "還原完成，共處理 $count 個檔案。"
    Write-Log '提醒：請到 Steam 移除這款遊戲的啟動選項，否則下次開遊戲又會自動更新回繁中。' 'WARN'
    return 0
}

# ---------------------------------------------------------------- 首次設定
function Invoke-Setup($Config, [string]$GameDir) {
    Write-Host ''
    Write-Host '=== Deadlock 繁體中文更新器：首次設定 ===' -ForegroundColor Cyan

    if ($ScriptDir -match '\\Temp\\' -or $ScriptDir -match '\.zip') {
        Write-Log '看起來你是直接在壓縮檔或暫存資料夾裡執行。請先把整個資料夾解壓縮到固定位置（例如 D:\deadlock_zhtw_localization）再重跑一次。' 'WARN'
        return 1
    }

    $code = Invoke-Update $Config $GameDir

    $launch = '"{0}" %command%' -f (Join-Path $ScriptDir 'launch.bat')
    try { Set-Clipboard -Value $launch } catch {}

    Write-Host ''
    Write-Host '下一步：把下面這行貼到 Steam 的啟動選項（已自動複製到剪貼簿）' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "    $launch" -ForegroundColor Green
    Write-Host ''
    Write-Host '  1. 開啟 Steam → 資料庫 → 對 Deadlock 按右鍵 → 內容'
    Write-Host '  2. 在「一般」分頁找到「啟動選項」，貼上（Ctrl+V）'
    Write-Host '  3. 關閉視窗即可。之後每次從 Steam 開遊戲都會先自動更新繁中'
    Write-Host ''
    Write-Host "更新記錄：$LogFile"
    return $code
}

# ---------------------------------------------------------------- 圖形介面
function Save-ConfigValue([string]$Name, $Value) {
    if ($UserSettingKeys -notcontains $Name) { throw "不允許儲存的設定：$Name" }
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $o = [ordered]@{}
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $old = [IO.File]::ReadAllText($SettingsFile, $Utf8NoBom).TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($k in $UserSettingKeys) { if ($null -ne $old.$k) { $o[$k] = $old.$k } }
        } catch {}
    }
    $o[$Name] = $Value
    [IO.File]::WriteAllText($SettingsFile, ([pscustomobject]$o | ConvertTo-Json), $Utf8NoBom)
}

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try {
        Add-Type -Namespace Zhtw -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
        [void][Zhtw.Native]::SetProcessDPIAware()
    } catch {}
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:GuiMode = $true
    $script:Quiet   = $true
    $script:Busy    = $false

    try { $script:Cfg = Get-Config }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Deadlock 繁體中文更新器', 'OK', 'Error')
        return
    }

    $F  = {
        param([float]$Size = 9, [string]$Style = 'Regular')
        New-Object System.Drawing.Font('Microsoft JhengHei UI', $Size, [System.Drawing.FontStyle]$Style)
    }
    $btn = {
        param([string]$Text, [int]$W = 130)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text; $b.Height = 32; $b.MinimumSize = New-Object System.Drawing.Size($W, 32)
        $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'; $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        $b.FlatStyle = 'System'
        return $b
    }
    $group = {
        param([string]$Title)
        $g = New-Object System.Windows.Forms.GroupBox
        $g.Text = $Title; $g.Dock = 'Fill'; $g.AutoSize = $true; $g.AutoSizeMode = 'GrowAndShrink'
        $g.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
        $g.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
        return $g
    }

    # ---- 主視窗
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Deadlock 繁體中文更新器'
    $form.Font = & $F 9
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.ClientSize = New-Object System.Drawing.Size(660, 640)
    $form.MinimumSize = New-Object System.Drawing.Size(660, 600)
    $form.StartPosition = 'CenterScreen'
    $script:Form = $form
    try {
        $icoPath = Join-Path $ScriptDir 'app.ico'   # 只有以 .ps1 執行時才用得到；exe 的圖示已內嵌
        if (Test-Path -LiteralPath $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
    } catch {}

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.ColumnCount = 1
    $root.Padding = New-Object System.Windows.Forms.Padding(14)
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    $form.Controls.Add($root)
    function Add-Row($ctl, [bool]$fill = $false) {
        $rs = if ($fill) { New-Object System.Windows.Forms.RowStyle('Percent', 100) } else { New-Object System.Windows.Forms.RowStyle('AutoSize') }
        [void]$root.RowStyles.Add($rs)
        [void]$root.Controls.Add($ctl)
    }

    # ---- 標題
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Deadlock 繁體中文更新器'; $title.Font = & $F 15 'Bold'
    $title.AutoSize = $true; $title.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    Add-Row $title

    # ---- 放在壓縮檔 / 暫存資料夾內的警告
    $lblWarn = New-Object System.Windows.Forms.Label
    $lblWarn.AutoSize = $true; $lblWarn.ForeColor = [System.Drawing.Color]::Firebrick
    $lblWarn.Text = '⚠ 目前在壓縮檔或暫存資料夾內執行。請先把整個資料夾解壓縮到固定位置（例如 D:\deadlock_zhtw_localization）再使用，否則 Steam 啟動選項會失效。'
    $lblWarn.MaximumSize = New-Object System.Drawing.Size(600, 0)
    $lblWarn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $lblWarn.Visible = [bool]($ScriptDir -match '\\Temp\\' -or $ScriptDir -match '\.zip')
    Add-Row $lblWarn

    # ---- 遊戲位置
    $gGame = & $group '遊戲位置'
    $tGame = New-Object System.Windows.Forms.TableLayoutPanel
    $tGame.Dock = 'Fill'; $tGame.AutoSize = $true; $tGame.ColumnCount = 3; $tGame.RowCount = 1
    [void]$tGame.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$tGame.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    [void]$tGame.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.ReadOnly = $true; $txtPath.Dock = 'Fill'; $txtPath.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
    $btnAuto   = & $btn '自動偵測' 90
    $btnBrowse = & $btn '瀏覽…' 80
    $btnBrowse.Margin = New-Object System.Windows.Forms.Padding(0)
    $tGame.Controls.Add($txtPath, 0, 0); $tGame.Controls.Add($btnAuto, 1, 0); $tGame.Controls.Add($btnBrowse, 2, 0)
    $gGame.Controls.Add($tGame)
    Add-Row $gGame

    # ---- 狀態
    $gStat = & $group '目前狀態'
    $tStat = New-Object System.Windows.Forms.FlowLayoutPanel
    $tStat.Dock = 'Fill'; $tStat.AutoSize = $true; $tStat.FlowDirection = 'TopDown'; $tStat.WrapContents = $false
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize = $true; $lblStatus.Font = & $F 11 'Bold'; $lblStatus.Text = '尚未檢查'
    $lblStatus.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $lblDetail = New-Object System.Windows.Forms.Label
    $lblDetail.AutoSize = $true; $lblDetail.ForeColor = [System.Drawing.Color]::DimGray
    $lblDetail.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $chkInfo = New-Object System.Windows.Forms.CheckBox
    $chkInfo.Text = '補上遊戲語言設定（gameinfo.gi）'; $chkInfo.AutoSize = $true
    $chkFont = New-Object System.Windows.Forms.CheckBox
    $chkFont.Text = '補上繁中字型規則（fonts.conf）'; $chkFont.AutoSize = $true
    $lblChkHint = New-Object System.Windows.Forms.Label
    $lblChkHint.AutoSize = $true; $lblChkHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblChkHint.Text = '取消勾選只是之後不再套用；要移除已套用的內容請按下方「還原成原版」。'
    $lblChkHint.MaximumSize = New-Object System.Drawing.Size(580, 0)
    foreach ($c in $lblStatus, $lblDetail, $chkInfo, $chkFont, $lblChkHint) { $tStat.Controls.Add($c) }
    $gStat.Controls.Add($tStat)
    Add-Row $gStat

    # ---- 主要按鈕
    $pMain = New-Object System.Windows.Forms.FlowLayoutPanel
    $pMain.AutoSize = $true; $pMain.Dock = 'Fill'; $pMain.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $btnCheck  = & $btn '檢查更新' 110
    $btnUpdate = & $btn '立即更新' 110
    $btnPlay   = & $btn '更新並啟動遊戲' 150
    $btnUpdate.Font = & $F 9 'Bold'
    foreach ($c in $btnCheck, $btnUpdate, $btnPlay) { $pMain.Controls.Add($c) }
    Add-Row $pMain

    # ---- Steam 啟動選項
    $gSteam = & $group 'Steam 啟動選項（只要設定一次）'
    $tSteam = New-Object System.Windows.Forms.TableLayoutPanel
    $tSteam.Dock = 'Fill'; $tSteam.AutoSize = $true; $tSteam.ColumnCount = 2; $tSteam.RowCount = 2
    [void]$tSteam.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$tSteam.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    $lblSteam = New-Object System.Windows.Forms.Label
    $lblSteam.AutoSize = $true; $lblSteam.MaximumSize = New-Object System.Drawing.Size(580, 0)
    $lblSteam.Text = '複製下面這行，貼到 Steam → 資料庫 → 對 Deadlock 按右鍵 → 內容 → 一般 → 啟動選項。之後每次從 Steam 開遊戲，都會先自動更新繁中。'
    $lblSteam.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $txtLaunch = New-Object System.Windows.Forms.TextBox
    $txtLaunch.ReadOnly = $true; $txtLaunch.Dock = 'Fill'; $txtLaunch.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
    # 有編好的無視窗啟動器就用它（Steam 不會在工作列留下 cmd 視窗），沒有就用 launch.bat
    $launcherExe = Join-Path $ScriptDir 'deadlock_zhtw_launcher.exe'
    $launchTarget = if (Test-Path -LiteralPath $launcherExe) { $launcherExe } else { Join-Path $ScriptDir 'launch.bat' }
    $txtLaunch.Text = '"{0}" %command%' -f $launchTarget
    $btnCopy = & $btn '複製' 80
    $btnCopy.Margin = New-Object System.Windows.Forms.Padding(0)
    $tSteam.Controls.Add($lblSteam, 0, 0); $tSteam.SetColumnSpan($lblSteam, 2)
    $tSteam.Controls.Add($txtLaunch, 0, 1); $tSteam.Controls.Add($btnCopy, 1, 1)
    $gSteam.Controls.Add($tSteam)
    Add-Row $gSteam

    # ---- 其他按鈕
    $pOther = New-Object System.Windows.Forms.FlowLayoutPanel
    $pOther.AutoSize = $true; $pOther.Dock = 'Fill'; $pOther.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $btnLog     = & $btn '開啟記錄檔' 100
    $btnFolder  = & $btn '開啟遊戲資料夾' 120
    $btnRestore = & $btn '還原成原版' 110
    foreach ($c in $btnLog, $btnFolder, $btnRestore) { $pOther.Controls.Add($c) }
    Add-Row $pOther

    # ---- 進度條 + 記錄
    $prog = New-Object System.Windows.Forms.ProgressBar
    $prog.Dock = 'Fill'; $prog.Height = 10; $prog.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $script:Progress = $prog
    Add-Row $prog

    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.ReadOnly = $true; $logBox.Dock = 'Fill'; $logBox.BackColor = [System.Drawing.Color]::White
    $logBox.BorderStyle = 'FixedSingle'; $logBox.MinimumSize = New-Object System.Drawing.Size(0, 120)
    $script:LogBox = $logBox
    Add-Row $logBox $true

    # ---------------- 共用
    $allButtons = @($btnAuto, $btnBrowse, $btnCheck, $btnUpdate, $btnPlay, $btnCopy, $btnRestore)
    $setBusy = {
        param([bool]$On)
        $script:Busy = $On
        foreach ($b in $allButtons) { $b.Enabled = -not $On }
        $chkInfo.Enabled = -not $On; $chkFont.Enabled = -not $On
        $form.UseWaitCursor = $On
        if (-not $On) { $script:Progress.Value = 0 }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $setStatus = {
        param([string]$Text, [string]$Kind = 'info')
        $lblStatus.Text = $Text
        $lblStatus.ForeColor = switch ($Kind) {
            'ok'    { [System.Drawing.Color]::SeaGreen }
            'warn'  { [System.Drawing.Color]::DarkOrange }
            'err'   { [System.Drawing.Color]::Firebrick }
            default { [System.Drawing.Color]::DimGray }
        }
    }
    $showDetail = {
        $st = Get-State
        $local = if ($st) { "本機版本 $($st.version)（$($st.updatedAt)）" } else { '本機版本：尚未更新過' }
        $remote = if ($script:LastResult) { "　｜　倉庫最新版本 $($script:LastResult.Version)" } else { '' }
        $lblDetail.Text = $local + $remote
    }
    $findGame = {
        $script:GameDir = Find-GameDir $script:Cfg
        if ($script:GameDir) { $txtPath.Text = $script:GameDir }
        else {
            $txtPath.Text = ''
            & $setStatus '找不到 Deadlock，請按「瀏覽…」選擇遊戲資料夾' 'err'
        }
    }
    $applyChecks = {
        $script:Cfg | Add-Member -NotePropertyName patchGameInfo -NotePropertyValue $chkInfo.Checked -Force
        $script:Cfg | Add-Member -NotePropertyName patchFonts    -NotePropertyValue $chkFont.Checked -Force
    }
    # mode: check（只檢查）/ update（寫入）。回傳 $true 表示沒有失敗
    $runWork = {
        param([string]$Mode)
        if (-not $script:GameDir) { & $setStatus '找不到 Deadlock，請先選擇遊戲資料夾' 'err'; return $false }
        $ok = $false
        & $setBusy $true
        try {
            & $applyChecks
            $script:CheckOnly = ($Mode -eq 'check')
            $script:PatchPending = 0
            $script:LastResult = $null
            $script:ProgressSink = { param($d, $t) $script:Progress.Maximum = [Math]::Max([int]$t, 1); $script:Progress.Value = [Math]::Min([int]$d, $script:Progress.Maximum); [System.Windows.Forms.Application]::DoEvents() }
            $script:TotalLimit = 180
            $Clock.Restart()
            & $setStatus $(if ($Mode -eq 'check') { '檢查中…' } else { '更新中…' }) 'info'

            Update-GameInfo $script:GameDir $script:Cfg
            Update-FontsConf $script:GameDir $script:Cfg
            $code = Invoke-Update $script:Cfg $script:GameDir
            $r = $script:LastResult

            if (-not $r) {
                & $setStatus '無法取得更新資訊（可能離線或 GitHub 連不上），詳見下方記錄' 'warn'
            } elseif ($r.Failed -gt 0) {
                & $setStatus "有 $($r.Failed) 個檔案處理失敗，詳見下方記錄" 'err'
            } elseif ($Mode -eq 'check') {
                $need = $r.Updated + $script:PatchPending
                if ($need -gt 0) { & $setStatus "有更新可用（$($r.Updated) 個檔案、$($script:PatchPending) 項補丁）" 'warn' }
                else { & $setStatus '繁體中文已是最新版' 'ok' }
                $ok = $true
            } else {
                & $setStatus "更新完成（更新 $($r.Updated) 個檔案，其餘 $($r.Same) 個已是最新）" 'ok'
                $ok = $true
            }
            & $showDetail
        } catch {
            Write-Log "發生錯誤：$($_.Exception.Message)" 'ERROR'
            & $setStatus '發生錯誤，詳見下方記錄' 'err'
        } finally {
            $script:CheckOnly = $false
            $script:ProgressSink = $null
            & $setBusy $false
        }
        return $ok
    }

    # ---------------- 事件
    $script:LogSink = {
        param($m, $l)
        $color = switch ($l) { 'ERROR' { 'Firebrick' } 'WARN' { 'DarkOrange' } default { 'Black' } }
        $rtb = $script:LogBox
        $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
        $rtb.SelectionColor = [System.Drawing.Color]::FromName($color)
        $rtb.AppendText(((Get-Date -Format 'HH:mm:ss') + '  ' + $m + "`n"))
        $rtb.ScrollToCaret()
    }

    $chkInfo.Checked = [bool]$script:Cfg.patchGameInfo
    $chkFont.Checked = [bool]$script:Cfg.patchFonts
    $chkInfo.Add_CheckedChanged({ try { Save-ConfigValue 'patchGameInfo' $chkInfo.Checked } catch { Write-Log "儲存設定失敗：$($_.Exception.Message)" 'ERROR' } })
    $chkFont.Add_CheckedChanged({ try { Save-ConfigValue 'patchFonts' $chkFont.Checked } catch { Write-Log "儲存設定失敗：$($_.Exception.Message)" 'ERROR' } })

    $btnCheck.Add_Click({ [void](& $runWork 'check') })
    $btnUpdate.Add_Click({ [void](& $runWork 'update') })
    $btnPlay.Add_Click({
        $ok = & $runWork 'update'
        if (-not $ok) {
            $a = [System.Windows.Forms.MessageBox]::Show('更新沒有完全成功，仍要啟動遊戲嗎？', 'Deadlock 繁體中文更新器', 'YesNo', 'Question')
            if ($a -ne 'Yes') { return }
        }
        try { Start-Process ('steam://rungameid/{0}' -f $script:Cfg.appId) }
        catch { Write-Log "無法啟動 Steam：$($_.Exception.Message)" 'ERROR' }
    })

    $btnAuto.Add_Click({
        try {
            Save-ConfigValue 'gamePath' ''
            $script:Cfg | Add-Member -NotePropertyName gamePath -NotePropertyValue '' -Force
            & $findGame
            if ($script:GameDir) { Write-Log "已偵測到遊戲：$($script:GameDir)"; & $setStatus '已找到遊戲' 'info' }
        } catch { Write-Log "偵測失敗：$($_.Exception.Message)" 'ERROR' }
    })
    $btnBrowse.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = '請選擇 Deadlock 的安裝資料夾（裡面要有 game 資料夾，通常是 …\steamapps\common\Deadlock）'
        if ($script:GameDir) { $d.SelectedPath = $script:GameDir }
        if ($d.ShowDialog() -ne 'OK') { return }
        if (-not (Test-Path -LiteralPath (Join-Path $d.SelectedPath 'game\citadel'))) {
            [void][System.Windows.Forms.MessageBox]::Show("這個資料夾裡找不到 game\citadel，看起來不是 Deadlock 的安裝資料夾。", 'Deadlock 繁體中文更新器', 'OK', 'Warning')
            return
        }
        try {
            Save-ConfigValue 'gamePath' $d.SelectedPath
            $script:Cfg | Add-Member -NotePropertyName gamePath -NotePropertyValue $d.SelectedPath -Force
            & $findGame
            Write-Log "已指定遊戲資料夾：$($d.SelectedPath)"
            & $setStatus '已指定遊戲資料夾，可以按「檢查更新」' 'info'
        } catch { Write-Log "儲存設定失敗：$($_.Exception.Message)" 'ERROR' }
    })

    $btnCopy.Add_Click({
        try { [System.Windows.Forms.Clipboard]::SetText($txtLaunch.Text); $btnCopy.Text = '已複製 ✓'; Write-Log '已複製 Steam 啟動選項，請貼到 Steam 的 Deadlock 內容 → 啟動選項。' }
        catch { Write-Log '無法寫入剪貼簿，請手動選取上方文字複製。' 'WARN' }
    })
    $btnLog.Add_Click({
        if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $LogFile) }
        else { Write-Log '還沒有記錄檔。' 'WARN' }
    })
    $btnFolder.Add_Click({
        if ($script:GameDir -and (Test-Path -LiteralPath $script:GameDir)) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:GameDir) }
    })
    $btnRestore.Add_Click({
        if (-not $script:GameDir) { & $setStatus '找不到 Deadlock，無法還原' 'err'; return }
        $a = [System.Windows.Forms.MessageBox]::Show("要把遊戲檔案還原成安裝繁中之前的狀態嗎？`n`n取代過的檔案會還原、新增的檔案會刪除，gameinfo.gi 與 fonts.conf 的補丁也會移除。", '還原成原版', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { return }
        & $setBusy $true
        try {
            $code = Invoke-Restore $script:GameDir $script:Cfg
            if ($code -eq 0) {
                & $setStatus '已還原成原版' 'ok'
                [void][System.Windows.Forms.MessageBox]::Show("已還原。`n`n請記得到 Steam 清空 Deadlock 的啟動選項，否則下次從 Steam 開遊戲又會自動更新回繁中。", '還原成原版', 'OK', 'Information')
            } else { & $setStatus '沒有可還原的內容（找不到備份）' 'warn' }
        } catch {
            Write-Log "還原失敗：$($_.Exception.Message)" 'ERROR'
            & $setStatus '還原失敗，詳見下方記錄' 'err'
        } finally { & $setBusy $false }
    })

    $form.Add_FormClosing({ if ($script:Busy) { $args[1].Cancel = $true } })
    $form.Add_Shown({
        & $findGame
        & $showDetail
        if ($script:GameDir) { [void](& $runWork 'check') }
    })

    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------- 主程式
try {
    Limit-LogSize
    if ($Gui) { Start-Gui; exit 0 }
    $cfg = Get-Config
    $gameDir = Find-GameDir $cfg
    if (-not $gameDir) {
        Write-Log '找不到 Deadlock 安裝位置。請確認已安裝遊戲；若遊戲不在 Steam 資料庫內，請改用圖形介面版手動選擇資料夾。' 'ERROR'
        exit 2
    }

    if ($Restore) { exit (Invoke-Restore $gameDir $cfg) }

    # 本機操作，不需要網路；Valve 更新把 gameinfo.gi 換回官方版後，下次啟動會自動補回
    Update-GameInfo $gameDir $cfg
    Update-FontsConf $gameDir $cfg

    if ($Setup)   { exit (Invoke-Setup $cfg $gameDir) }
    else          { exit (Invoke-Update $cfg $gameDir) }
} catch {
    Write-Log "未預期的錯誤：$($_.Exception.Message)" 'ERROR'
    exit 1
}
