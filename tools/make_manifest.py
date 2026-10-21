#!/usr/bin/env python3
"""產生 / 檢查 manifest.json

倉庫的 files/ 目錄結構 = 遊戲安裝目錄內的相對路徑，例如：
    files/game/citadel/resource/localization/xxx_tchinese.txt
會對應到玩家本機的：
    <Deadlock 安裝目錄>/game/citadel/resource/localization/xxx_tchinese.txt

用法：
    python3 tools/make_manifest.py            # 檢查並寫出 manifest.json
    python3 tools/make_manifest.py --check    # 只檢查，不寫檔（PR 驗證用）
"""
import argparse
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SCHEMA = 1
# 白名單：只允許這些目錄、這些副檔名（需與 client/config.json 保持一致）
DEFAULT_PREFIXES = ("game/citadel/", "game/citadel_tchinese/")
DEFAULT_EXT = (".txt", ".vpk", ".gi", ".conf")
VPK_MAGIC = b"\x34\x12\xaa\x55"  # VPK 檔頭 0x55AA1234（little-endian）


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def decode_text(data: bytes) -> str:
    """接受 UTF-8（含或不含 BOM）與帶 BOM 的 UTF-16。"""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16")
    return data.decode("utf-8-sig")


def check_keyvalues(text: str) -> list[str]:
    """簡易 KeyValues 語法檢查：引號是否閉合、大括號是否成對。"""
    errors = []
    depth = 0
    line = 1
    i, n = 0, len(text)
    in_quote = False
    quote_line = 0
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
        if in_quote:
            if c == "\\" and i + 1 < n:
                if text[i + 1] == "\n":
                    line += 1
                i += 2
                continue
            if c == '"':
                in_quote = False
        else:
            if c == '"':
                in_quote = True
                quote_line = line
            elif c == "/" and i + 1 < n and text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    i += 1
                continue
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth < 0:
                    errors.append(f"第 {line} 行：多出一個 }}")
                    depth = 0
        i += 1
    if in_quote:
        errors.append(f"第 {quote_line} 行開始的引號沒有閉合")
    if depth > 0:
        errors.append(f"缺少 {depth} 個 }}")
    return errors


def check_content(ext: str, data: bytes, kv: bool = True) -> list[str]:
    """依副檔名檢查內容，回傳錯誤訊息清單（空清單 = 通過）。"""
    if ext == ".vpk":
        return [] if data[:4] == VPK_MAGIC else ["不是有效的 VPK 檔（檔頭不符）"]
    try:
        text = decode_text(data)
    except UnicodeDecodeError as e:
        return [f"編碼無法解讀（需為 UTF-8 或帶 BOM 的 UTF-16）：{e}"]
    if ext == ".conf":
        try:
            ET.fromstring(data)
        except ET.ParseError as e:
            return [f"XML 格式錯誤：{e}"]
        return []
    if ext in (".txt", ".gi") and kv:
        return check_keyvalues(text)
    return []


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="倉庫根目錄（預設：目前目錄）")
    ap.add_argument("--files-dir", default="files")
    ap.add_argument("--out", default="manifest.json")
    ap.add_argument("--check", action="store_true", help="只檢查，不寫出 manifest")
    ap.add_argument("--no-kv-check", action="store_true", help="略過 .txt / .gi 的 KeyValues 語法檢查")
    ap.add_argument("--allowed-prefix", action="append", default=None,
                    help=f"允許的目標路徑前綴，可重複指定（預設：{', '.join(DEFAULT_PREFIXES)}）")
    ap.add_argument("--allowed-ext", action="append", default=None,
                    help=f"允許的副檔名，可重複指定（預設：{', '.join(DEFAULT_EXT)}）")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    files_dir = root / args.files_dir
    prefixes = tuple(args.allowed_prefix or DEFAULT_PREFIXES)
    exts = tuple(e.lower() for e in (args.allowed_ext or DEFAULT_EXT))

    if not files_dir.is_dir():
        print(f"找不到目錄：{files_dir}", file=sys.stderr)
        return 1

    errors: list[str] = []
    entries = []

    for p in sorted(files_dir.rglob("*")):
        if not p.is_file() or any(part.startswith(".") for part in p.relative_to(files_dir).parts):
            continue
        rel = p.relative_to(files_dir).as_posix()

        if ".." in rel.split("/") or "\\" in rel or ":" in rel:
            errors.append(f"{rel}：路徑含有不允許的字元")
            continue
        if not rel.startswith(prefixes):
            errors.append(f"{rel}：不在允許的目錄內（{', '.join(prefixes)}）")
            continue
        if p.suffix.lower() not in exts:
            errors.append(f"{rel}：副檔名不在允許清單（{', '.join(exts)}）")
            continue

        data = p.read_bytes()
        if not data:
            errors.append(f"{rel}：檔案是空的")
            continue
        problems = check_content(p.suffix.lower(), data, kv=not args.no_kv_check)
        if problems:
            errors.extend(f"{rel}：{m}" for m in problems)
            continue

        entries.append({"path": rel, "sha256": sha256_bytes(data), "size": len(data)})

    if not entries and not errors:
        errors.append("files/ 底下沒有任何可發佈的檔案")

    if errors:
        print("檢查失敗：", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        return 1

    # version 由檔案內容決定：內容沒變 → manifest 完全相同 → CI 不會產生多餘 commit
    digest = hashlib.sha256("".join(f"{e['path']}:{e['sha256']};" for e in entries).encode()).hexdigest()
    manifest = {"schema": SCHEMA, "version": digest[:12], "files": entries}

    print(f"檢查通過：{len(entries)} 個檔案，version {manifest['version']}")
    for e in entries:
        print(f"  ✓ {e['path']}  ({e['size']} bytes)")

    if args.check:
        return 0

    out = root / args.out
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"已寫出 {out.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
