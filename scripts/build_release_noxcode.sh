#!/usr/bin/env bash
# ============================================================================
# build_release_noxcode.sh — 无 Xcode 环境构建 icopool (Copool) 发行版
#
# 适用于只有 CommandLineTools（无完整 Xcode）的机器 / agent。
# 产物: dist/icopool.app（ad-hoc 签名，可直接本地分发）
#
# 用法:
#   ./scripts/build_release_noxcode.sh               # 构建 + 组装 dist/icopool.app
#   ./scripts/build_release_noxcode.sh --deploy      # 额外部署到 /Applications/icopool.app 并重启
#   ./scripts/build_release_noxcode.sh --zip         # 额外打包 dist/icopool-<ver>-macOS-signed.zip + sha256
#   ./scripts/build_release_noxcode.sh --app <path>  # 指定目标 app bundle（默认 dist/icopool.app）
#   ./scripts/build_release_noxcode.sh --skip-build  # 跳过 swift build，只用现有 .build/release 产物组装
#
# 关键背景（详见 docs/release-noxcode.md）:
#   - macOS 27 SDK 中 @State 变成 Swift 宏 (SwiftUIMacros.StateMacro)，
#     CommandLineTools 不带该宏插件 => 编译失败。必须用 26.5(或更早) SDK。
#   - 新工具链的 Bundle.module 按 <app>/Contents/Resources/Copool_Copool.bundle
#     查找资源 => 组装时必须把整个 bundle 拷进 app。
#   - 签名用 ad-hoc（codesign --sign -），不是 Developer ID；不需要公证。
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DEPLOY=0
ZIP=0
SKIP_BUILD=0
APP_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy) DEPLOY=1 ;;
    --zip) ZIP=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --app) APP_PATH="$2"; shift ;;
    -h|--help) grep '^#' "$0" | head -20; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

log() { printf '[build_release_noxcode] %s\n' "$*"; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1" >&2; exit 1; }
}

require_command swift
require_command codesign
require_command ditto
require_command plutil

# ---- 1. 版本号（从 project.yml 读取，避免硬编码） -------------------------
MARKETING_VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | awk '{print $2}')"
CURRENT_PROJECT_VERSION="$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | awk '{print $2}')"
[[ -n "$MARKETING_VERSION" && -n "$CURRENT_PROJECT_VERSION" ]] || {
  echo "无法从 project.yml 读取版本号" >&2; exit 1
}
log "版本: ${MARKETING_VERSION} (${CURRENT_PROJECT_VERSION})"

# ---- 2. 选择 SDK（避免 macOS 27 SDK 的 SwiftUIMacros 宏问题） ---------------
pick_sdk() {
  # 优先 26.x SDK；没有则退回默认 SDK（若是 27.x 且编译报 SwiftUIMacros，按文档换机器/装旧 SDK）
  for s in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX25.sdk
  do
    [[ -d "$s" ]] && { echo "$s"; return 0; }
  done
  xcrun --show-sdk-path
}
SDK="$(pick_sdk)"
log "使用 SDK: $SDK"
if [[ "$SDK" == *27* ]]; then
  log "警告: 检测到 macOS 27 SDK，@State 宏 (SwiftUIMacros) 在 CommandLineTools 下无法编译，若构建失败请改用 26.5 SDK"
fi

# ---- 3. 构建 ---------------------------------------------------------------
if [[ "$SKIP_BUILD" == "1" ]]; then
  log "跳过构建（--skip-build），使用现有 .build/release 产物"
else
  log "swift build -c release（--sdk ${SDK}）"
  swift build -c release --sdk "$SDK"
fi

BIN="$ROOT_DIR/.build/release/Copool"
ROUTER_HOST="$ROOT_DIR/.build/release/CopoolRouterHost"
BUNDLE="$ROOT_DIR/.build/release/Copool_Copool.bundle"
[[ -f "$BIN" && -f "$ROUTER_HOST" && -d "$BUNDLE" ]] || {
  echo "构建产物不完整: 需要 $BIN / $ROUTER_HOST / $BUNDLE" >&2; exit 1
}

# bundle 资源根：新布局平铺在 bundle 根，旧布局在 Contents/Resources
BUNDLE_RESROOT="$BUNDLE"
[[ -d "$BUNDLE/Contents/Resources" ]] && BUNDLE_RESROOT="$BUNDLE/Contents/Resources"

# ---- 4. 组装 app bundle ------------------------------------------------------
TARGET="${APP_PATH:-$ROOT_DIR/dist/icopool.app}"
log "组装目标: $TARGET"

mkdir -p "$TARGET/Contents/MacOS" "$TARGET/Contents/Resources"

# 4.1 Info.plist：已有则更新版本；没有则从模板创建
if [[ -f "$TARGET/Contents/Info.plist" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" \
                          -c "Set :CFBundleVersion ${CURRENT_PROJECT_VERSION}" \
                          "$TARGET/Contents/Info.plist"
else
  sed -e "s/\$(DEVELOPMENT_LANGUAGE)/en/" \
      -e "s/\$(EXECUTABLE_NAME)/icopool/" \
      -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.alick.copool/" \
      -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/" \
      -e "s/\$(MARKETING_VERSION)/${MARKETING_VERSION}/" \
      -e "s/\$(CURRENT_PROJECT_VERSION)/${CURRENT_PROJECT_VERSION}/" \
      "$ROOT_DIR/Sources/Copool/Info-macOS.plist" > "$TARGET/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Copool" "$TARGET/Contents/Info.plist" 2>/dev/null || true
fi

# 4.2 主二进制 + RouterHost helper
cp "$BIN" "$TARGET/Contents/MacOS/icopool"
cp "$ROUTER_HOST" "$TARGET/Contents/MacOS/CopoolRouterHost"
chmod 755 "$TARGET/Contents/MacOS/icopool" "$TARGET/Contents/MacOS/CopoolRouterHost"

# 4.3 资源：保留图标，其余清空重建
ICON_SRC=""
if [[ -f "$TARGET/Contents/Resources/Copool.icns" ]]; then
  ICON_SRC="$TARGET/Contents/Resources/Copool.icns"
elif [[ -f "$ROOT_DIR/dist/icopool.app/Contents/Resources/Copool.icns" ]]; then
  ICON_SRC="$ROOT_DIR/dist/icopool.app/Contents/Resources/Copool.icns"
fi
TMP_KEEP="$(mktemp -d)"
[[ -n "$ICON_SRC" ]] && cp "$ICON_SRC" "$TMP_KEEP/Copool.icns"
rm -rf "$TARGET/Contents/Resources"/*
cp -R "$BUNDLE_RESROOT/." "$TARGET/Contents/Resources/"
# 新 Bundle.module 运行时按 Resources/Copool_Copool.bundle 查找 —— 必须整体拷入
rm -rf "$TARGET/Contents/Resources/Copool_Copool.bundle"
cp -R "$BUNDLE" "$TARGET/Contents/Resources/Copool_Copool.bundle"
[[ -f "$TMP_KEEP/Copool.icns" ]] && cp "$TMP_KEEP/Copool.icns" "$TARGET/Contents/Resources/"
rm -rf "$TMP_KEEP"

# 4.4 ad-hoc 签名（先清旧签名再签，避免残留影响验证）
codesign --remove-signature "$TARGET" 2>/dev/null || true
codesign --force --deep --sign - "$TARGET"
codesign --verify --deep --strict "$TARGET"
log "签名验证通过 (ad-hoc)"

log "组装完成: $TARGET (${MARKETING_VERSION} build ${CURRENT_PROJECT_VERSION})"

# ---- 5. 部署到 /Applications（可选） -----------------------------------------
if [[ "$DEPLOY" == "1" ]]; then
  DEPLOY_TARGET="/Applications/icopool.app"
  log "部署到 $DEPLOY_TARGET"
  pkill -f "icopool.app/Contents/MacOS/icopool" 2>/dev/null || true
  sleep 2
  rm -rf "$DEPLOY_TARGET"
  cp -R "$TARGET" "$DEPLOY_TARGET"
  codesign --force --deep --sign - "$DEPLOY_TARGET"
  codesign --verify --deep --strict "$DEPLOY_TARGET"
  open "$DEPLOY_TARGET"
  sleep 8
  if pgrep -f "icopool.app/Contents/MacOS/icopool" >/dev/null; then
    log "应用已启动"
    KEY="${KEY:-$HOME/.codex-tools-proxyd/api-proxy.key}"
    if [[ -f "$KEY" ]]; then
      log "代理 health:"
      curl -s -m 8 -H "Authorization: Bearer $(cat "$KEY")" \
        http://127.0.0.1:8787/v1/models | head -c 120 || true
      echo
    fi
  else
    log "警告: 应用未在运行，检查 ~/Library/Logs/DiagnosticReports 是否有新崩溃"
  fi
fi

# ---- 6. 打包 zip（可选） ------------------------------------------------------
if [[ "$ZIP" == "1" ]]; then
  ZIP_PATH="$ROOT_DIR/dist/icopool-${MARKETING_VERSION}-macOS-signed.zip"
  rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$ZIP_PATH"
  shasum -a 256 "$ZIP_PATH" | awk '{print $1"  icopool-'"${MARKETING_VERSION}"'-macOS-signed.zip"}' > "$ZIP_PATH.sha256"
  log "zip: $ZIP_PATH ($(du -h "$ZIP_PATH" | awk '{print $1}'))"
  cat "$ZIP_PATH.sha256"
fi

log "完成: Copool ${MARKETING_VERSION} (${CURRENT_PROJECT_VERSION})"
