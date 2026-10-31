# Deadlock 繁體中文更新器

每次從 Steam 啟動 Deadlock 前，自動把本機的繁體中文檔案同步到最新版，再開遊戲。遊戲更新把繁中檔案蓋掉時，下次啟動也會自動補回。

## 下載

到 [Releases](https://github.com/Racpy/deadlock_zhtw_localization/releases) 下載其中一種：

| 版本 | 檔案 | 適合 |
|---|---|---|
| **GUI 版**（推薦） | `Deadlock_zhTW_Updater_GUI.zip` | 想要視窗介面：偵測遊戲、檢查更新、複製 Steam 啟動選項、還原，全部用按的。Steam 啟動時**不會**在工作列留下黑視窗 |
| **NoGUI 版** | `Deadlock_zhTW_Updater_NoGUI.zip` | 偏好純文字腳本（`.bat` + `.ps1`），內容全部可以直接檢視 |

兩種版本做的事完全一樣，擇一使用即可。

## 使用方式

先把 zip **解壓縮到固定位置**（例如 `D:\Deadlock_zhTW_Updater`）。不要放在下載資料夾，也不要在壓縮檔內直接執行；之後搬動資料夾的話，Steam 啟動選項要重新設定。

### GUI 版

1. 雙擊 `deadlock_zhtw_updater.exe`，會自動偵測遊戲並檢查更新。
2. 按「立即更新」。
3. 按「Steam 啟動選項」旁的「複製」，到 Steam → 資料庫 → 對 Deadlock 按右鍵 → 內容 → 一般 → 啟動選項，貼上。
4. 之後從 Steam 開遊戲就會自動更新。

偵測不到遊戲時按「瀏覽…」選擇 Deadlock 的安裝資料夾（裡面要有 `game` 資料夾）。

### NoGUI 版

1. 雙擊 `setup.bat`：找到遊戲、更新一次，並把 Steam 啟動選項複製到剪貼簿。
2. 到 Steam → 資料庫 → 對 Deadlock 按右鍵 → 內容 → 一般 → 啟動選項，貼上。
3. 之後從 Steam 開遊戲就會自動更新。

## 不想用了

- **GUI 版**：按「還原成原版」，再把 Steam 的啟動選項清空。
- **NoGUI 版**：雙擊 `restore.bat`，再把 Steam 的啟動選項清空。

還原會把取代過的檔案換回原本的、刪除新增的檔案，並移除 `gameinfo.gi` 與 `fonts.conf` 的補丁。Steam 的啟動選項沒清空的話，下次開遊戲又會更新回繁中。

## 它會改動什麼

只會動遊戲資料夾內的這些位置：

- `game/citadel/resource/localization/` 等繁體中文語言檔
- `game/citadel_tchinese/`（繁中資源包）
- `game/citadel/gameinfo.gi`：只在 `SupportedLanguages` 區段補上 `"tchinese" "3"`，其餘保持 Valve 的最新版
- `game/citadel/panorama/fonts/fonts.conf`：加入一段 zh-tw 字型規則（用 `BEGIN/END deadlock_zhtw_localization` 註解標記，可乾淨移除）

程式自己的記錄、備份、設定都放在程式旁邊的 `data` 資料夾（`update.log`、`backup/`、`settings.json`），刪掉整個程式資料夾就不會留下別的東西。

## 安全設計

| 項目 | 作法 |
|---|---|
| 找遊戲 | 讀 Steam 登錄檔 → `libraryfolders.vdf` → `appmanifest_1422450.acf`，支援多個資料庫磁碟 |
| 只更新有差異的 | 比對本機檔案與清單的 SHA256，每次啟動只下載約 1 KB 的清單，不使用 GitHub API |
| 下載驗證 | 下載後再驗一次 SHA256，不符就捨棄，不會寫入半成品；先寫暫存檔再取代 |
| 路徑白名單 | 只允許寫入上面列出的目錄與 `.txt` `.vpk` `.gi` `.conf` 檔，並擋掉 `..`、絕對路徑；不會碰遊戲執行檔 |
| 補丁保護 | `gameinfo.gi`、`fonts.conf` 補丁寫入前會確認格式；找不到插入位置（Valve 改了格式）就略過並記錄 |
| 備份 | `data/backup/original/` 保存第一次覆寫前的原始檔（只存一次），`data/backup/previous/` 保存上一版 |
| 不擋遊戲 | 離線、GitHub 連不上、任何錯誤都只寫進記錄，遊戲照常啟動；啟動時最多等約 30 秒 |

## 常見問題

- **更新沒有生效？** 開啟 `data/update.log`（GUI 版可按「開啟記錄檔」）查看原因。
- **剛有新翻譯，我卻拿到舊版？** GitHub 的檔案有數分鐘快取，稍等再試。
- **Windows 跳出 SmartScreen / 防毒警告？** 程式沒有數位簽章，可能被標示為不明發行者。對 zip 按右鍵 → 內容 → 勾選「解除封鎖」後再解壓縮，或在警告畫面選「仍要執行」。NoGUI 版全是明文腳本，可自行檢視；GUI 版的原始碼也都在本倉庫的 `client/` 內。
- **GUI 版開不起來？** 需要 Windows 10 / 11 內建的 PowerShell 5.1 與 .NET Framework，一般系統都有。
- **風險提醒**：修改遊戲目錄內的檔案不受 Valve 官方支援，請自行評估並自負風險。

## 想參與翻譯？

見 [CONTRIBUTING.md](CONTRIBUTING.md)。
