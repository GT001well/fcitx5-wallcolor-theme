#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/theme-common.sh"
test_theme="$themes_dir/wallpaper-theme-dev"
state_dir="$state_home/fcitx5-wallpaper-theme-test"
backup="$state_dir/classicui.conf.backup"

reload_fcitx_config_quiet() {
  fcitx5_running || return 0
  reload_fcitx_config ||
    printf 'warning: 配置已恢复，但 Fcitx5 未响应 Classic UI 热重载请求\n' >&2
}

remove_test_theme() {
  [[ "$test_theme" == "$themes_dir/wallpaper-theme-dev" ]] ||
    die "refusing to remove unexpected theme path: $test_theme"
  if [[ -d "$test_theme" ]]; then
    find -- "$test_theme" -mindepth 1 -delete
    rmdir -- "$test_theme"
  fi
}

uses_test_theme() {
  grep -Eq '^(Theme|DarkTheme)=wallpaper-theme-dev$' "$config"
}

if [[ ! -d "$state_dir" ]]; then
  if [[ -e "$test_theme" ]]; then
    die "没有测试备份，但测试主题仍存在：$test_theme"
  fi
  printf '没有需要恢复的测试主题。\n'
  exit 0
fi

[[ -f "$config" ]] || die "找不到 Fcitx5 配置：$config"

if [[ ! -f "$backup" ]]; then
  if [[ -e "$test_theme" ]] || uses_test_theme; then
    die "没有配置备份，但当前仍在引用测试主题；请手动检查后恢复"
  fi

  find -- "$state_dir" -mindepth 1 -maxdepth 1 -type f \
    \( -name 'fcitx-*.log' -o -name 'classicui.conf.backup.*' \) -delete
  rmdir -- "$state_dir" ||
    die "状态目录仍包含未知文件：$state_dir"
  printf '原配置已恢复；已清理残留测试状态。\n'
  exit 0
fi

temporary=$(mktemp "${config}.restore.XXXXXX")
cp -- "$backup" "$temporary"
chmod --reference="$config" "$temporary"
mv -- "$temporary" "$config"

reload_fcitx_config_quiet
remove_test_theme
rm -f -- "$backup"
rm -f -- "$state_dir"/fcitx-*.log "$state_dir"/classicui.conf.backup.*
rmdir -- "$state_dir" 2>/dev/null || true

printf '已恢复原 Fcitx5 主题配置。\n'
