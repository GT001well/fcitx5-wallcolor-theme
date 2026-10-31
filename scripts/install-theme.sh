#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/theme-common.sh"
backup_dir="$state_home/fcitx5-wallpaper-theme"
backup="$backup_dir/classicui.conf.backup"
theme_name=wechat-green
accent_color=
view_only=0
sample_image=0
selected_image=
staging_dir=
previous_theme_dir=
rollback_config=
config_committed=0

usage() {
  cat <<'EOF'
用法：
  ./install.sh                         安装微信绿默认主题
  ./install.sh --color '#2AAE67'       使用指定颜色生成并应用 local
  ./install.sh -p                      打开选择器，采样后生成并应用 local
  ./install.sh -p "图片路径"           直接采样指定图片

附加选项：
  --view          显示实际路径和执行命令，不写文件
  -h, --help      显示帮助
EOF
}

quote() {
  printf '%q' "$1"
}

remove_tree() {
  local directory=$1
  [[ -n "$directory" && -d "$directory" ]] || return 0
  find -- "$directory" -mindepth 1 -delete
  rmdir -- "$directory"
}

cleanup_theme_install() {
  local exit_code=$?
  local temporary
  trap - EXIT INT TERM HUP
  set +e
  if [[ $config_committed -eq 0 && -n "$rollback_config" && -f "$rollback_config" ]]; then
    temporary=$(mktemp "${config}.rollback.XXXXXX")
    cp -- "$rollback_config" "$temporary"
    chmod --reference="$config" "$temporary"
    mv -- "$temporary" "$config"
    rm -f -- "$rollback_config"
  fi
  if [[ -n "$previous_theme_dir" && -d "$previous_theme_dir" ]]; then
    if [[ $config_committed -eq 0 ]]; then
      remove_tree "$theme_dir"
      mv -- "$previous_theme_dir" "$theme_dir"
    else
      remove_tree "$previous_theme_dir"
    fi
  fi
  if [[ -n "$staging_dir" ]]; then
    remove_tree "$staging_dir"
  fi
  exit "$exit_code"
}

pick_image() {
  local selected
  if [[ -n "${FCITX_THEME_IMAGE:-}" ]]; then
    selected=$FCITX_THEME_IMAGE
  elif command -v kdialog >/dev/null 2>&1; then
    selected=$(kdialog \
      --title '选择取色图片' \
      --getopenfilename "$HOME/Pictures" \
      '图片 (*.png *.jpg *.jpeg *.webp *.avif)') || return 1
  elif command -v zenity >/dev/null 2>&1; then
    selected=$(zenity \
      --file-selection \
      --title='选择取色图片' \
      --file-filter='图片 | *.png *.jpg *.jpeg *.webp *.avif') || return 1
  else
    die "需要 kdialog 或 zenity 选择图片"
  fi
  [[ -f "$selected" ]] || return 1
  printf '%s' "$selected"
}

print_sample_plan() {
  printf '图片采样与安装计划：\n'
  printf -- '- 使用 kdialog 或 zenity 选择一张本地图片\n'
  printf -- '- 使用 ImageMagick 量化主色并校正明度、饱和度和文字对比度\n'
  printf -- '- 将采样结果写入主题 local\n'
  printf -- '- 安装目录：%s\n' "$themes_dir/local"
  printf -- '- 启用 Theme=local、DarkTheme=local\n'
  printf -- '- 热重载 Classic UI；Fcitx5 未运行时跳过\n'
}

print_plan() {
  local backup_state
  local staging_pattern="$themes_dir/.${theme_name}.staging.XXXXXX"
  if [[ -f "$backup" ]]; then
    backup_state="保留现有备份"
  else
    backup_state="创建新备份"
  fi

  printf '安装计划：\n'
  printf -- '- 主题：%s\n' "$theme_name"
  printf -- '- 源目录：%s\n' "$source_theme"
  printf -- '- 安装目录：%s\n' "$theme_dir"
  printf -- '- 配置：%s\n' "$config"
  printf -- '- 备份：%s（%s）\n' "$backup" "$backup_state"
  if [[ -n "$accent_color" ]]; then
    printf -- '- 强调色：%s\n' "$accent_color"
  elif [[ -n "$selected_image" ]]; then
    printf -- '- 强调色：从 %s 采样\n' "$selected_image"
  else
    printf -- '- 强调色：使用主题预设\n'
  fi

  printf '\n执行步骤：\n'
  if [[ -f "$backup" ]]; then
    printf '1. 备份配置：保留 %s\n' "$(quote "$backup")"
  else
    printf '1. 备份配置：\n   cp -- %s %s\n' \
      "$(quote "$config")" "$(quote "$backup")"
  fi
  printf '2. 暂存主题：\n   %s\n' "$(quote "$staging_pattern")"
  printf '3. 原子替换主题：暂存目录 -> %s\n' "$(quote "$theme_dir")"
  if [[ -n "$accent_color" ]]; then
    printf '4. 写入主题色：\n   python3 %s --theme %s --color %s\n' \
      "$(quote "$repo_root/scripts/set-theme-accent.py")" \
      "$(quote "$staging_pattern")" \
      "$(quote "$accent_color")"
  else
    printf '4. 写入主题色：使用 %s 预设\n' "$theme_name"
  fi
  printf '5. 启用主题：%s\n' "$(quote "$config")"
  printf '   Theme=%s\n' "$theme_name"
  printf '   DarkTheme=%s\n' "$theme_name"
  printf '   UseDarkTheme=False\n'
  printf '   UseAccentColor=False\n'
  printf '6. 热重载 Classic UI；Fcitx5 未运行时跳过。\n'
}

reload_installed_theme() {
  if ! fcitx5_running; then
    printf 'Fcitx5 未运行；主题已安装，下次启动会直接读取。\n'
    return 0
  fi

  reload_fcitx_config ||
    die "Classic UI 热重载失败"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      sample_image=1
      theme_name=local
      shift
      if [[ $# -gt 0 && "$1" != -* ]]; then
        selected_image=$1
        shift
      fi
      ;;
    --color)
      [[ $# -ge 2 ]] || die "--color 需要颜色值"
      accent_color=$2
      theme_name=local
      shift 2
      ;;
    --view)
      view_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

if [[ $sample_image -eq 1 && -n "$accent_color" ]]; then
  die "-p 与 --color 不能同时使用"
fi

if [[ $sample_image -eq 1 && $view_only -eq 1 ]]; then
  print_sample_plan
  exit 0
fi

if [[ $sample_image -eq 1 ]]; then
  if [[ -z "$selected_image" ]]; then
    selected_image=$(pick_image) ||
      die "未选择图片或选择已取消"
  fi
  command -v magick >/dev/null 2>&1 ||
    die "缺少命令：magick"
  accent_color=$(python3 "$repo_root/scripts/sample-image-color.py" "$selected_image") ||
    die "从图片提取颜色失败"
fi

source_theme="$repo_root/themes/$theme_name"
theme_dir="$themes_dir/$theme_name"
[[ -f "$source_theme/theme.conf" ]] ||
  die "找不到主题：$source_theme"

if [[ $view_only -eq 1 ]]; then
  print_plan
  if [[ -n "$accent_color" ]]; then
    python3 "$repo_root/scripts/set-theme-accent.py" \
      --theme "$source_theme" \
      --color "$accent_color" \
      --dry-run
  fi
  exit 0
fi

[[ -f "$config" ]] || die "缺少 Fcitx5 配置：$config"
for command in python3 fcitx5-remote gdbus; do
  command -v "$command" >/dev/null 2>&1 ||
    die "缺少命令：$command"
done
if [[ $sample_image -eq 1 ]]; then
  command -v magick >/dev/null 2>&1 || die "缺少命令：magick"
fi

mkdir -p -- "$themes_dir" "$backup_dir"
if [[ ! -f "$backup" ]]; then
  cp -- "$config" "$backup"
fi
rollback_config=$(mktemp "$backup_dir/classicui.conf.rollback.XXXXXX")
cp -- "$config" "$rollback_config"
trap cleanup_theme_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
staging_dir=$(mktemp -d "$themes_dir/.${theme_name}.staging.XXXXXX")
cp -a -- "$source_theme/." "$staging_dir/"

if [[ -n "$accent_color" ]]; then
  python3 "$repo_root/scripts/set-theme-accent.py" \
    --theme "$staging_dir" \
    --color "$accent_color" \
    --quiet
fi

previous_theme_dir="$themes_dir/.${theme_name}.previous.$$"
[[ ! -e "$previous_theme_dir" ]] ||
  die "临时目录已存在：$previous_theme_dir"
if [[ -e "$theme_dir" ]]; then
  mv -- "$theme_dir" "$previous_theme_dir"
fi
if ! mv -- "$staging_dir" "$theme_dir"; then
  die "无法替换主题目录：$theme_dir"
fi
staging_dir=

set_key Theme "$theme_name" "$config"
set_key DarkTheme "$theme_name" "$config"
set_key UseDarkTheme "False" "$config"
set_key UseAccentColor "False" "$config"

config_committed=1
rm -f -- "$rollback_config"
rollback_config=
remove_tree "$previous_theme_dir"
previous_theme_dir=
trap - EXIT INT TERM HUP

reload_installed_theme

if [[ "$theme_name" == local ]]; then
  printf '已安装并启用 local（强调色 %s）。\n' "$accent_color"
else
  printf '已安装并启用 wechat-green（默认配色）。\n'
fi
