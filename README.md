# Deadlock 繁體中文更新器

翻譯者把繁中檔案 PR 到這個倉庫 → 合併後 GitHub 自動產生 `manifest.json` →
玩家每次從 Steam 啟動 Deadlock 時，小程式先把本機的繁中檔案同步到最新版，再開遊戲。

```
翻譯者 ──PR──▶ main ──GitHub Actions──▶ manifest.json（檔案清單 + SHA256）
                                              │
玩家按 Steam「開始遊戲」                          │
   └─▶ launch.bat ─▶ deadlock_zhtw_localization.ps1 ◀───────┘ 比對本機檔案，只下載有差異的
          └─▶ 啟動 Deadlock
```

## 倉庫結構

```
deadlock_zhtw_localization/
├─ files/                      ← 繁中檔案放這裡（路徑 = 遊戲目錄內的相對路徑）
│   └─ game/citadel/resource/localization/…   例：xxx_tchinese.txt
├─ manifest.json               ← 自動產生，請勿手動修改
├─ client/                     ← 給玩家用的更新器
│   ├─ setup.bat               首次設定（雙擊執行）
│   ├─ launch.bat              Steam 啟動選項掛這個
│   ├─ restore.bat             還原成安裝前的檔案
│   ├─ deadlock_zhtw_localization.ps1        更新器本體
│   └─ config.json             設定（要先填你的 GitHub 帳號）
├─ tools/make_manifest.py      產生 manifest + 檢查格式
└─ .github/workflows/          自動化
```

**新增、刪除、改名檔案不用改任何程式**：只要讓 `files/` 底下的路徑與遊戲內的路徑一致即可，manifest 會自動更新。

> **例外：下面兩個 Valve 的檔案不要放進 `files/`**（放進去 PR 檢查會直接失敗）。
> 它們每次遊戲更新都可能變動，整檔取代會把新版蓋成舊版，所以更新器改用「補丁」處理，其餘內容保持 Valve 的最新版：
>
> | 檔案 | 補丁內容 | 在哪裡修改 |
> |---|---|---|
> | `game/citadel/gameinfo.gi` | 在 `SupportedLanguages` 區段補上 `"tchinese" "3"` | 固定，不需修改 |
> | `game/citadel/panorama/fonts/fonts.conf` | 插入 zh-tw 字型規則（`VALVEPulp`、`Reaver`、`Retail Demo`） | `client/deadlock_zhtw_localization.ps1` 的 `$FontsBlockBody` |
>
> 修改字型規則的方式：改 `$FontsBlockBody` 後發佈新版更新器，玩家下次啟動就會自動把舊規則換成新規則（區塊用 `BEGIN/END deadlock_zhtw_localization` 註解標記，不會重複、也能乾淨移除）。
> 不想讓更新器動這兩個檔案，可在 `client/config.json` 把 `patchGameInfo` / `patchFonts` 改成 `false`。

---

## 一、你（維護者）的一次性設定

1. 在 GitHub 建立倉庫（建議名稱 `deadlock_zhtw_localization`，設為 Public），把這個資料夾的內容推上去。
2. 開啟 `client/config.json`，把 `repoOwner` 改成你的 GitHub 帳號名稱。
3. **確認遊戲內的實際路徑**：到你電腦的 Deadlock 安裝目錄，找到現有繁中檔案的位置，然後
   - 把檔案依相同的相對路徑放進 `files/`（例如 `files/game/citadel/resource/localization/xxx.txt`）；
   - 若要放行新的目錄或副檔名，要**同時修改兩處**白名單，兩邊必須一致：
     `client/config.json` 的 `allowedPrefixes` / `allowedExtensions`，以及 `tools/make_manifest.py` 的 `DEFAULT_PREFIXES` / `DEFAULT_EXT`。
     （每個項目要各自是一個字串，例如 `[".txt", ".vpk"]`，不能寫成 `[".txt, .vpk"]`。）
     白名單請盡量收窄到實際用到的目錄，不要直接放行整個 `game/`。
4. GitHub 倉庫 → Settings → Actions → General → Workflow permissions，選 **Read and write permissions**（讓機器人能提交 manifest）。
5. 若 `main` 有開分支保護，要允許 `github-actions[bot]` 繞過，否則 manifest 無法自動提交。
6. 推上去後到 Actions 分頁手動執行一次 **Update manifest**，確認倉庫根目錄出現 `manifest.json`。
7. 發佈更新器給玩家：打 tag `client-v1.0.0` 並推送，Actions 會把 `client/` 打包成 `deadlock_zhtw_localization-Updater.zip` 放到 Releases。

## 二、翻譯者的流程

1. Fork 倉庫 → 修改 `files/` 內的檔案 → 發 Pull Request。
2. PR 會自動跑格式檢查（編碼、引號、大括號是否成對、路徑是否合法），不通過會顯示紅色 ✗ 與原因。
3. 維護者審核並合併後，約一分鐘內 manifest 自動更新，玩家下次開遊戲就會拿到新版。

> **編碼**：檔案需為 UTF-8（可帶 BOM）或帶 BOM 的 UTF-16，與遊戲原本的檔案保持一致即可。
> 倉庫已設定不轉換換行字元（`.gitattributes`），請勿用編輯器的「自動轉換換行」功能重新存檔。

## 三、玩家的使用方式

1. 到 Releases 下載 `deadlock_zhtw_localization-Updater.zip`，**解壓縮到固定位置**（例如 `D:\deadlock_zhtw_localization`，不要放在下載資料夾或壓縮檔內直接執行）。
2. 雙擊 `setup.bat`。它會找到遊戲、更新一次，並把 Steam 啟動選項複製到剪貼簿。
3. Steam → 資料庫 → Deadlock 右鍵 → 內容 → 一般 → 啟動選項，貼上並關閉視窗。
4. 之後從 Steam 開遊戲就會自動更新。遊戲本體更新覆蓋了繁中檔案時，下次啟動也會自動修復。

不想用了：雙擊 `restore.bat` 還原（取代過的檔案還原、新增的檔案刪除、`gameinfo.gi` 與 `fonts.conf` 移除補丁），並清空 Steam 的啟動選項。

## 運作細節與安全設計

| 項目 | 作法 |
|---|---|
| 找遊戲 | 讀 Steam 登錄檔 → `libraryfolders.vdf` → `appmanifest_1422450.acf`，支援多個資料庫磁碟；也可在 `config.json` 的 `gamePath` 手動指定 |
| 只更新有差異的 | 比對本機檔案與 manifest 的 SHA256 |
| 下載驗證 | 下載後再驗一次 SHA256，不符就捨棄，不會寫入半成品 |
| 寫入方式 | 先寫暫存檔再取代，避免中途失敗留下壞檔 |
| 路徑白名單 | 只允許寫入 `allowedPrefixes` 目錄內的 `allowedExtensions` 檔案，並擋掉 `..`、絕對路徑；就算倉庫被入侵，也無法覆寫遊戲執行檔 |
| gameinfo.gi 補丁 | 不整檔取代；只在 `SupportedLanguages` 區段補上 `"tchinese" "3"`，保留原本的換行與縮排。已經有就不動；找不到區段（Valve 改了格式）就略過並記錄。這是本機操作，離線也會套用，所以 Valve 更新把檔案換回官方版後，下次啟動會自動補回 |
| fonts.conf 補丁 | 把 zh-tw 字型規則用 `BEGIN/END` 註解包起來，插在 Valve 的 `Use English font globally…` 註解之前（順序會影響 fontconfig 比對，不能放到檔尾）。寫入前先確認結果是合法 XML，不合法就取消；找不到插入點就略過並記錄 |
| 備份 | `backup/original/` 保存第一次覆寫前的原始檔（只存一次），`backup/previous/` 保存上一版 |
| 不擋遊戲 | 離線、GitHub 無法連線、任何錯誤都只記錄到 `update.log`，遊戲照常啟動；整體最多等待約 30 秒 |
| 流量 | 每次啟動只下載約 1 KB 的 manifest，檔案有變才下載，不使用 GitHub API，沒有 60 次/小時的限制 |

## 常見問題

- **更新沒有生效？** 看 `client/update.log`。若出現「不在允許的目錄內」，代表路徑白名單與實際路徑不一致（見上方設定第 3 步）。
- **剛合併 PR，玩家卻拿到舊版？** `raw.githubusercontent.com` 有數分鐘快取，稍等即可。
- **Windows 跳出 SmartScreen / 防毒警告？** 下載的 `.bat` / `.ps1` 可能被標記為網路來源。對 zip 按右鍵 → 內容 → 勾選「解除封鎖」後再解壓縮；或在警告畫面選「仍要執行」。程式碼全部是明文，可自行檢視。
- **規範提醒**：修改遊戲目錄內的本地化檔案，建議先確認 Valve 目前的政策，並在說明中提醒玩家風險自負。
