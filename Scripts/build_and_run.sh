#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="macos-dock-cc-v2"
CLI_NAME="window-lab"
PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/macos-dock-cc-v2.xcodeproj"
DERIVED_DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  xcodebuild -project "$PROJECT_PATH" -scheme "$APP_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >/tmp/macos-dock-cc-v2-build.log 2>&1
}

run_cli() {
  xcodebuild -project "$PROJECT_PATH" -scheme "$CLI_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >/tmp/macos-dock-cc-v2-build.log 2>&1
  "$DERIVED_DATA_DIR/Build/Products/Debug/$CLI_NAME" "$@"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
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
    open_app
    ;;
  --debug|debug)
    build_app
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.caye.macosdockcc.v2\""
    ;;
  --verify|verify)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
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
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--lab|--lab-minimize|--lab-close|--lab-replay [scenario-name]|--lab-placement [scenario-name]|--lab-transition [scenario-name]]" >&2
    exit 2
    ;;
esac
