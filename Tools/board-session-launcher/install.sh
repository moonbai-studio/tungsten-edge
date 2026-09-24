#!/bin/zsh
# 安装「Tungsten Edge 开会话」启动器小程序到 ~/Applications，让进度看板每条工作线的「▶ co / cf / cv」按钮
# （tungsten-cc:// 链接）能开一个 Ghostty 窗口跑 co / cf / cv 并把开场白灌进输入框。
# 前提：Ghostty ≥ 1.2、~/.zshrc 里有 co / cf / cv 三个别名、官网仓库在本仓库旁边（或用 WEB_DIR= 指定）。
# 重复运行 = 整个重装（仓库挪了位置要重跑）。卸载：删掉 ~/Applications/Tungsten Edge 开会话.app。
set -euo pipefail

here="${0:A:h}"
app_dir="${here:h:h}"
web_dir="${WEB_DIR:-${app_dir:h}/Tungsten Edge web}"
app="$HOME/Applications/Tungsten Edge 开会话.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -d "$web_dir" ]] || print -u2 "提示：官网仓库不在 $web_dir，官网线的按钮会报「目录不存在」；可用 WEB_DIR=<路径> 重跑"
[[ -d /Applications/Ghostty.app ]] || { print -u2 "找不到 /Applications/Ghostty.app"; exit 1; }

helper="$app/Contents/Resources/open-session.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed "s|__HELPER__|$helper|" "$here/launcher.applescript" >"$tmp/launcher.applescript"

rm -rf "$app"
mkdir -p "${app:h}"
/usr/bin/osacompile -o "$app" "$tmp/launcher.applescript"
sed -e "s|__APP_DIR__|$app_dir|" -e "s|__WEB_DIR__|$web_dir|" "$here/open-session.py" >"$helper"

plist="$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string app.tungstenedge.session-launcher "$plist"
/usr/bin/plutil -replace LSUIElement -bool true "$plist"
/usr/bin/plutil -replace CFBundleURLTypes -json '[{"CFBundleURLName":"Tungsten Edge Session","CFBundleURLSchemes":["tungsten-cc"]}]' "$plist"
# 改了 Info.plist，osacompile 给的临时签名就失效了，重签一次。
/usr/bin/codesign --force --deep --sign - "$app"
"$lsregister" -f "$app"

print "已安装：$app（链接 tungsten-cc://open?line=…&model=cf|co|cv&dir=app|web&text=…）"
