#!/usr/bin/env bash
# Linux 编译打包脚本
# 用法:
#   ./scripts/build-linux.sh              # 编译 release 并打包 tar.gz
#   ./scripts/build-linux.sh --with-deps  # 先安装系统编译依赖(需要 sudo)，再编译打包
#
# 产物:
#   build/linux/<arch>/release/bundle/    # 可直接运行的目录
#   dist/media-player-<version>-linux-<arch>.tar.gz
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------- 工具函数 ----------

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 系统依赖(可选, --with-deps) ----------

install_system_deps() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "--with-deps 仅支持 Debian/Ubuntu/Mint(apt)。其他发行版请手动安装等价包: clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev"
  fi
  log "安装系统编译依赖 (需要 sudo)..."
  sudo apt-get update -qq
  sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
}

[[ "${1:-}" == "--with-deps" ]] && install_system_deps

# ---------- Flutter SDK ----------

if ! command -v flutter >/dev/null 2>&1; then
  # 本机默认安装位置(见 README)兜底
  if [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
    export PATH="$HOME/development/flutter/bin:$PATH"
  else
    die "未找到 flutter。安装方法见 README「Linux 构建与运行」，或将其加入 PATH。"
  fi
fi

log "Flutter: $(flutter --version | head -1)"

# 版本检查: pubspec 要求 sdk: ^3.13.0
dart_ver="$(dart --version 2>&1 | grep -oP 'Dart SDK version: \K[0-9]+\.[0-9]+')"
dart_min="3.13"
if [[ -n "$dart_ver" ]] && printf '%s\n%s\n' "$dart_min" "$dart_ver" | sort -V -C; then
  : # dart_ver >= 3.13, 通过
else
  die "Dart $dart_ver 低于项目要求的 3.13。请升级 Flutter(当前 stable 即可)。"
fi

# ---------- 编译 ----------

# 首次为老项目补充 linux 平台目录(已存在则跳过)
if [[ ! -d linux ]]; then
  log "添加 linux 平台支持..."
  flutter create --platforms=linux .
fi

log "拉取 Dart 依赖..."
flutter pub get

log "编译 Linux release..."
flutter build linux --release

# ---------- 打包 ----------

arch="$(uname -m)"
case "$arch" in
  x86_64)  arch="x64" ;;
  aarch64) arch="arm64" ;;
  *) warn "未识别的架构 $arch, 沿用原始名称打包" ;;
esac

version_line="$(grep -m1 '^version:' pubspec.yaml)"
version="${version_line#version:}"
version="${version//\"/}"
version="${version//\'/}"
version="${version//[[:space:]]/}"
[[ -n "$version" ]] || die "无法从 pubspec.yaml 解析 version 字段"
bundle="build/linux/${arch}/release/bundle"
[[ -x "$bundle/media_player" ]] || die "未找到编译产物 $bundle/media_player"

pkg_name="media-player-${version}-linux-${arch}"
mkdir -p dist
rm -rf "dist/${pkg_name}"
cp -r "$bundle" "dist/${pkg_name}"

tar -czf "dist/${pkg_name}.tar.gz" -C dist "$pkg_name"
rm -rf "dist/${pkg_name}"

log "打包完成: dist/${pkg_name}.tar.gz ($(du -h "dist/${pkg_name}.tar.gz" | cut -f1))"
echo
echo "本机直接运行:   $bundle/media_player"
echo "解压分发包后:   tar xzf ${pkg_name}.tar.gz && ./${pkg_name}/media_player"
echo "注意: 目标机器需安装 libmpv2 (Debian/Ubuntu: sudo apt install libmpv2)"
