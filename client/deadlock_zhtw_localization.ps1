<#
  Deadlock 繁體中文更新器

  用法（通常不需要手動執行，由 setup.bat / launch.bat 呼叫）：
    -Setup      首次設定：偵測遊戲、更新一次、產生 Steam 啟動選項
    -Restore    還原成安裝前的狀態（取代的檔案還原、gameinfo.gi / fonts.conf 的補丁移除）
    -CheckOnly  只檢查哪些檔案需要更新，不寫入
    -Quiet      不顯示訊息（launch.bat 使用），只寫入 update.log

  離線、網路失敗、GitHub 掛掉時，只會記錄到 update.log，不會阻擋遊戲啟動。
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Restore,
    [switch]$CheckOnly,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$ScriptDir = $PSScriptRoot
$LogFile   = Join-Path $ScriptDir 'update.log'
$BackupDir = Join-Path $ScriptDir 'backup'
$Clock     = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- 記錄
function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
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
function Get-Config {
    $path = Join-Path $ScriptDir 'config.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "找不到 config.json：$path" }
    $c = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

    $defaults = @{
        appId             = 1422450
        branch            = 'main'
        gamePath          = ''
        timeoutSec        = 8
        maxTotalSec       = 30
        maxFileSizeMB     = 20
        allowedPrefixes   = @('game/citadel/resource/localization/')
        allowedExtensions = @('.txt')
        patchGameInfo     = $true
        patchFonts        = $true
    }
    foreach ($k in $defaults.Keys) {
        if ($null -eq $c.$k -or ($c.$k -is [string] -and $c.$k -eq '' -and $k -ne 'gamePath')) {
            $c | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        }
    }
    if (-not $c.repoOwner -or $c.repoOwner -eq 'YOUR_GITHUB_NAME' -or -not $c.repoName) {
        throw 'config.json 的 repoOwner / repoName 尚未填寫'
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
        Write-Log "config.json 指定的 gamePath 不存在：$($Config.gamePath)" 'WARN'
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
        $bytes = $client.GetByteArrayAsync($Url).GetAwaiter().GetResult()
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

        if ($CheckOnly) { Write-Log "需要補丁：$GameInfoRel（加入 tchinese 語言）"; return }

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
        if ($CheckOnly) { Write-Log "需要補丁：$FontsRel（zh-tw 字型規則）"; return }

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
    foreach ($f in $manifest.files) {
        if ($Clock.Elapsed.TotalSeconds -gt [int]$Config.maxTotalSec) {
            Write-Log "已超過 $($Config.maxTotalSec) 秒，停止本次更新（下次啟動再試）" 'WARN'
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

# ---------------------------------------------------------------- 主程式
try {
    Limit-LogSize
    $cfg = Get-Config
    $gameDir = Find-GameDir $cfg
    if (-not $gameDir) {
        Write-Log '找不到 Deadlock 安裝位置。請確認已安裝遊戲，或在 config.json 的 gamePath 手動填寫路徑。' 'ERROR'
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
