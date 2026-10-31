#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/theme-common.sh"
theme_name="${1:-wechat-green}"
[[ $# -le 1 ]] || {
  printf 'usage: %s [theme-name]\n' "${0##*/}" >&2
  exit 2
}
[[ "$theme_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'error: invalid theme name: %s\n' "$theme_name" >&2
  exit 2
}
source_theme="$repo_root/themes/$theme_name"
if [[ -f "$themes_dir/$theme_name/theme.conf" ]]; then
  source_theme="$themes_dir/$theme_name"
fi
test_theme="$themes_dir/wallpaper-theme-dev"
state_dir="$state_home/fcitx5-wallpaper-theme-test"
backup="$state_dir/classicui.conf.backup"

uses_test_theme() {
  grep -Eq '^(Theme|DarkTheme)=wallpaper-theme-dev$' "$config"
}

cleanup_stale_state() {
  [[ -d "$state_dir" && ! -f "$backup" ]] || return 1
  if [[ -e "$test_theme" ]] || uses_test_theme; then
    return 1
  fi

  find -- "$state_dir" -mindepth 1 -maxdepth 1 -type f \
    \( -name 'fcitx-*.log' -o -name 'classicui.conf.backup.*' \) -delete
  rmdir -- "$state_dir" 2>/dev/null || return 1
  printf '已清理上次测试留下的日志。\n'
}

remove_test_theme() {
  if [[ "$test_theme" != "$themes_dir/wallpaper-theme-dev" ]]; then
    printf 'error: refusing to remove unexpected theme path: %s\n' \
      "$test_theme" >&2
    return 1
  fi
  if [[ -d "$test_theme" ]]; then
    find -- "$test_theme" -mindepth 1 -delete || return 1
    rmdir -- "$test_theme" || return 1
  fi
}

restore_config() {
  local temporary

  temporary=$(mktemp "${config}.restore.XXXXXX") || return 1
  cp -- "$backup" "$temporary" || return 1
  chmod --reference="$config" "$temporary" || return 1
  mv -- "$temporary" "$config" || return 1
}

cleanup() {
  local exit_code=$?
  local cleanup_failed=0

  trap - EXIT INT TERM HUP
  set +e

  if [[ -f "$backup" ]]; then
    if restore_config; then
      reload_fcitx_config ||
        printf 'warning: 原配置已恢复，但 Fcitx5 未响应热重载请求\n' >&2
    else
      printf 'error: 无法恢复 Fcitx5 配置；备份和测试主题均已保留。\n' >&2
      cleanup_failed=1
    fi
  fi

  if [[ $cleanup_failed -eq 0 ]]; then
    remove_test_theme || cleanup_failed=1
  fi

  if [[ $cleanup_failed -eq 0 ]]; then
    rm -f -- "$backup" "$state_dir"/fcitx-*.log \
      "$state_dir"/classicui.conf.backup.* || cleanup_failed=1
    rmdir -- "$state_dir" 2>/dev/null || true
    printf '\n已恢复原 Fcitx5 主题配置。\n'
  else
    printf '手动恢复命令：%s/scripts/restore-theme.sh\n' "$repo_root" >&2
    ((exit_code != 0)) || exit_code=1
  fi

  exit "$exit_code"
}

[[ -d "$source_theme" ]] || die "缺少主题目录：$source_theme"
[[ -f "$config" ]] || die "缺少 Fcitx5 配置：$config"
command -v fcitx5-remote >/dev/null 2>&1 ||
  die "找不到 fcitx5-remote"
command -v gdbus >/dev/null 2>&1 ||
  die "找不到 gdbus，无法热重载 Classic UI 插件"
command -v awk >/dev/null 2>&1 || die "找不到 awk"

fcitx5_running ||
  die "Fcitx5 未运行；本脚本不会启动或重启 Fcitx5，请先手动启动后再测试"

cleanup_stale_state ||
  if [[ -e "$state_dir" ]]; then
    die "发现未完成的测试状态，请先运行 scripts/restore-theme.sh"
  fi
[[ ! -e "$test_theme" ]] ||
  die "测试主题目录已存在：$test_theme"

mkdir -p -- "$state_dir" "$themes_dir"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

backup_temporary=$(mktemp "${backup}.XXXXXX")
cp -- "$config" "$backup_temporary"
chmod --reference="$config" "$backup_temporary"
mv -- "$backup_temporary" "$backup"
cp -a -- "$source_theme" "$test_theme"

set_key Theme "wallpaper-theme-dev" "$config"
set_key DarkTheme "wallpaper-theme-dev" "$config"
set_key UseDarkTheme "False" "$config"
set_key UseAccentColor "False" "$config"

reload_fcitx_config ||
  die "Fcitx5 热重载失败"

cat <<'EOF'
测试主题已热切换，已重载 Classic UI 插件；Fcitx5 进程没有退出或重启。

请在另一个窗口中：
1. 激活 Fcitx5
2. 切换到中州韵并输入包含多个候选词的内容
3. 检查模糊、圆角、阴影、高亮和文字对比度
4. 截取真实候选框作为预览

如果候选框外观没有变化，请打开 Fcitx5 配置工具，重新应用
Classic UI 设置。不要退出或重启 Fcitx5。

回到此终端按 Enter 或 Ctrl+C 恢复原主题。
EOF

read -r _ || true
