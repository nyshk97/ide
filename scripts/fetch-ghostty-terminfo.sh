#!/usr/bin/env bash
# Ghostty の terminfo (xterm-ghostty / ghostty / Ghostty) を Resources/terminfo/ に生成する。
#
# libghostty (GhosttyKit.xcframework) は子プロセスのシェルに必ず
#   TERM=xterm-ghostty
#   TERMINFO=<GHOSTTY_RESOURCES_DIR の隣>/terminfo
# をセットするが、xcframework には terminfo 本体が同梱されていない。
# スタンドアロン Ghostty.app は Contents/Resources/terminfo/ に持っているので、
# 同じ場所（GhosttyManager が GHOSTTY_RESOURCES_DIR を <bundle>/Contents/Resources/ghostty
# に向けるので、その隣 = <bundle>/Contents/Resources/terminfo）に bundle する。
# 無いと terminfo が引けず、カーソル移動・行クリアのエスケープシーケンスが
# 全滅して入力中の表示が崩れる（`'xterm-ghostty': unknown terminal type.`）。
#
# 取得元: ghostty 本体の src/terminfo/ghostty.zig（GhosttyKit.xcframework/.ghostty_sha で pin）
#   ※ ghostty 本体もこの Zig 定義から terminfo source を生成して tic にかけている。
#     ここでは Source.zig の encode と同じフォーマットで source を起こして tic -x する。
# xcframework を更新したら（.ghostty_sha が変わったら）再実行する。差分は git で確認すること。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Resources/terminfo"
SHA_FILE="$REPO_ROOT/GhosttyKit.xcframework/.ghostty_sha"

if [ ! -f "$SHA_FILE" ]; then
  echo "error: $SHA_FILE が無い。GhosttyKit.xcframework が壊れている？" >&2
  exit 1
fi
SHA="$(tr -d '[:space:]' < "$SHA_FILE")"
URL="https://raw.githubusercontent.com/ghostty-org/ghostty/${SHA}/src/terminfo/ghostty.zig"

command -v tic >/dev/null || { echo "error: tic が無い（ncurses）" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 が無い" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> downloading ghostty.zig @ ${SHA:0:12}…"
curl -fsSL "$URL" -o "$tmp/ghostty.zig"

echo "==> generating terminfo source…"
python3 - "$tmp/ghostty.zig" > "$tmp/ghostty.terminfo" <<'PY'
import re, sys

raw = open(sys.argv[1], encoding="utf-8").read()

# Zig の行コメント // ... を除去（コメント内の "xterm-" や "formal" を名前/値と誤認しないため）。
# 文字列リテラル内の // は残す。
def strip_comments(text: str) -> str:
    out_lines = []
    for line in text.split('\n'):
        in_str = False
        i = 0
        cut = len(line)
        while i < len(line):
            ch = line[i]
            if ch == '"' and (i == 0 or line[i - 1] != '\\'):
                in_str = not in_str
            elif not in_str and ch == '/' and i + 1 < len(line) and line[i + 1] == '/':
                cut = i
                break
            i += 1
        out_lines.append(line[:cut])
    return '\n'.join(out_lines)

src = strip_comments(raw)

# .names = &.{ "xterm-ghostty", "ghostty", "Ghostty" },
m = re.search(r'\.names\s*=\s*&\.\{(.*?)\}\s*,', src, re.S)
if not m:
    sys.exit("could not find .names in ghostty.zig")
names = re.findall(r'"([^"]*)"', m.group(1))
if not names:
    sys.exit("no names parsed")

# .{ .name = "X", .value = .{ .<kind> = <{}|N|"..."> } },
cap_re = re.compile(
    r'\.name\s*=\s*"((?:[^"\\]|\\.)*)"\s*,\s*\.value\s*=\s*\.\{\s*'
    r'\.(boolean|canceled|numeric|string)\s*=\s*'
    r'(?:\{\}|(\d+)|"((?:[^"\\]|\\.)*)")',
    re.S,
)

def unescape_zig(s: str) -> str:
    # この terminfo 定義で実際に使われる Zig エスケープは \\ と \" のみ。
    # \E ^G %p1 等の terminfo 記法は文字列リテラル中で \\E のように書かれており
    # （= リテラル backslash + E）、そのまま素通しすれば tic が解釈する。
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            n = s[i + 1]
            if n in ('\\', '"', "'"):
                out.append(n); i += 2; continue
        out.append(c); i += 1
    return ''.join(out)

caps = []
for cm in cap_re.finditer(src):
    name, kind, num, strv = cm.group(1), cm.group(2), cm.group(3), cm.group(4)
    if kind == 'boolean':
        caps.append(name)
    elif kind == 'canceled':
        caps.append(name + '@')
    elif kind == 'numeric':
        caps.append(f'{name}#{num}')
    else:  # string
        caps.append(f'{name}={unescape_zig(strv or "")}')

if not caps:
    sys.exit("no capabilities parsed")

print('|'.join(names) + ',')
for c in caps:
    print('\t' + c + ',')
PY

echo "==> compiling with tic -x…"
rm -rf "$DEST"
mkdir -p "$DEST"
# -x: 拡張(ユーザー定義)ケーパビリティも保存 / -o: 出力先 / 警告は出るが致命的でなければ続行
tic -x -o "$DEST" "$tmp/ghostty.terminfo"

echo "==> wrote terminfo to $DEST"
find "$DEST" -type f -print | sed 's/^/    /'
echo
echo "確認: infocmp -A \"$DEST\" xterm-ghostty | head"
echo "次に: project.yml に Resources/terminfo が含まれていることを確認し、mise run build"
