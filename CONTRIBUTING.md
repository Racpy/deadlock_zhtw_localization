# 參與翻譯

1. Fork 本倉庫，修改 `files/` 內的檔案，發 Pull Request。
2. PR 會自動檢查格式（編碼、引號、大括號是否成對、路徑是否合法），不通過會顯示原因。
3. 合併後約一分鐘內 `manifest.json` 會自動更新，玩家下次開遊戲就會拿到新版。

## 檔案放哪裡

`files/` 底下的路徑 = 遊戲安裝資料夾內的相對路徑，例如：

```
files/game/citadel/resource/localization/citadel_main/citadel_main_tchinese.txt
→ <Deadlock>/game/citadel/resource/localization/citadel_main/citadel_main_tchinese.txt
```

新增、刪除、改名檔案不需要改任何程式。

## 請注意

- **編碼**：UTF-8（可帶 BOM），或帶 BOM 的 UTF-16，與遊戲原本的檔案一致即可。
- **不要用編輯器的「自動轉換換行」重新存檔**：倉庫不轉換換行字元，換行一變，檔案的 SHA256 就會跟著變。
- **不要把 Valve 會隨遊戲更新的檔案放進 `files/`**（`gameinfo.gi`、`fonts.conf`）。這兩個檔案由更新器用「補丁」處理，整檔取代會把新版蓋成舊版。字型規則在 `client/core/deadlock_zhtw_localization.ps1` 的 `$FontsBlockBody`。
- **只允許寫入白名單內的路徑與副檔名**（`game/citadel/`、`game/citadel_tchinese/`；`.txt` `.vpk` `.gi` `.conf`）。要放行新的位置，需同時修改 `tools/make_manifest.py` 的 `DEFAULT_PREFIXES` / `DEFAULT_EXT` 與 `client/core/deadlock_zhtw_localization.ps1` 的 `$Defaults`，兩邊必須一致。

## 本機檢查

```
python3 tools/make_manifest.py --check
```

## 建置更新器

```
powershell -ExecutionPolicy Bypass -File tools\build_client.ps1
```

會在 `dist/` 產生 GUI 版與 NoGUI 版兩個 zip（GUI 版需要在 Windows 上編譯，第一次會自動安裝 ps2exe）。發佈時打 tag `client-vX.Y.Z` 並推送，GitHub Actions 會自動編譯並放到 Releases。
