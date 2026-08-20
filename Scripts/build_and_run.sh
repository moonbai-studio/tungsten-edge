#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="macos-dock-cc-v2"
CLI_NAME="window-lab"
PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/macos-dock-cc-v2.xcodeproj"
DERIVED_DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# 必须和 install_local_release.sh 用同一张证书：开发构建与已安装包 bundle id 相同，
# 共用一条辅助功能授权记录，两边身份不一致就会互相作废。
DEVELOPER_ID="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Suzhou Mubai Creativity Design Co., Ltd. (DRPT2MJQD5)}"
FALLBACK_SIGNING_IDENTITY="macos-dock-cc Local Code Signing"

build_app() {
  xcodebuild -project "$PROJECT_PATH" -scheme "$APP_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >/tmp/macos-dock-cc-v2-build.log 2>&1
}

sign_app() {
  local identities identity
  identities="$(security find-identity -v -p codesigning 2>&1)"
  if grep -Fq "\"$DEVELOPER_ID\"" <<<"$identities"; then
    identity="$DEVELOPER_ID"
  elif grep -Fq "\"$FALLBACK_SIGNING_IDENTITY\"" <<<"$identities"; then
    identity="$FALLBACK_SIGNING_IDENTITY"
  else
    echo "warning: no signing identity found; keeping Xcode's build signature" >&2
    return 0
  fi
  # 刻意不加 --options runtime / --entitlements。hardened runtime 会挡住调试器附加
  # （我们的 entitlements 文件会整个替换掉 Xcode 给 Debug 自动注入的 get-task-allow），
  # --debug 模式下的 lldb 就废了。TCC 认的是证书链 + bundle id，跟 runtime 标志无关，
  # 所以只要证书一致，授权就和日常包共用。
  #
  # 自 Sparkle 落地起 bundle 里**不再只有一个可执行文件**：Sparkle.framework 里还有
  # Updater.app 和 Autoupdate。Xcode 在 Debug 构建时用的是项目里配的本地证书，
  # 这里若只重签外层，框架和外层就会挂着两张不同的证书——Sparkle 会因为更新器与宿主
  # 签名不一致而拒绝启动它。所以嵌套代码也要跟着重签一遍，顺序同样由内向外。
  # 依旧不加 --deep：该参数已被苹果废弃，且会把外层的签名选项错误地套到嵌套代码上。
  local framework="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$framework" ]]; then
    for nested in "$framework/Versions/B/Updater.app" "$framework/Versions/B/Autoupdate"; do
      [[ -e "$nested" ]] && /usr/bin/codesign --force --sign "$identity" "$nested" >>/tmp/macos-dock-cc-v2-codesign.log 2>&1
    done
    /usr/bin/codesign --force --sign "$identity" "$framework" >>/tmp/macos-dock-cc-v2-codesign.log 2>&1
  fi
  /usr/bin/codesign --force --sign "$identity" "$APP_BUNDLE" >>/tmp/macos-dock-cc-v2-codesign.log 2>&1
}

run_cli() {
  xcodebuild -project "$PROJECT_PATH" -scheme "$CLI_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >/tmp/macos-dock-cc-v2-build.log 2>&1
  "$DERIVED_DATA_DIR/Build/Products/Debug/$CLI_NAME" "$@"
}

# 先确认旧进程真的退干净了再启动。原先这里用 `open -n`（强制再开一个新实例），
# 只要 pkill 慢一拍或有别处启动的实例没被 pkill 覆盖到，屏幕上就会出现两条一模一样
# 的任务条，验收时根本分不清测的是哪个版本。
wait_for_exit() {
  local attempt
  for attempt in $(seq 1 25); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  echo "warning: 旧实例 5 秒内未退出，强制结束" >&2
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.3
}

open_app() {
  wait_for_exit
  /usr/bin/open "$APP_BUNDLE"
}

wait_for_app() {
  local attempt
  for attempt in $(seq 1 20); do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

case "$MODE" in
  run)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    ;;
  --debug|debug)
    build_app
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.caye.macosdockcc.v2\""
    ;;
  --launch-trace|launch-trace)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    wait_for_exit
    DOCK_LAUNCH_TRACE=1 "$APP_EXECUTABLE" > /tmp/launch-trace.log 2>&1 &
    wait_for_app
    echo "launch trace: /tmp/launch-trace.log"
    ;;
  --verify|verify)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    wait_for_app
    ;;
  --lab|lab)
    run_cli "${@:2}"
    ;;
  --lab-minimize|lab-minimize)
    run_cli minimizeRestore "${@:2}"
    ;;
  --lab-close|lab-close)
    run_cli closeTarget "${@:2}"
    ;;
  --lab-replay|lab-replay)
    run_cli replay "${2:-minimize-restore-replay}"
    ;;
  --lab-placement|lab-placement)
    run_cli placementReplay "${2:-placement-permanent-hold-replay}"
    ;;
  --lab-transition|lab-transition)
    run_cli transitionReplay "${2:-focused-active-replay}"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--launch-trace|--verify|--lab|--lab-minimize|--lab-close|--lab-replay [scenario-name]|--lab-placement [scenario-name]|--lab-transition [scenario-name]]" >&2
    exit 2
    ;;
esac
