#!/usr/bin/env bash

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
config="$config_home/fcitx5/conf/classicui.conf"
themes_dir="$data_home/fcitx5/themes"
export config_home data_home state_home config themes_dir

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

set_key() {
  local key=$1
  local value=$2
  local file=$3
  local temporary

  temporary=$(mktemp "${file}.XXXXXX")
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ ("^" key "=") {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "$file" > "$temporary"
  chmod --reference="$file" "$temporary"
  mv -- "$temporary" "$file"
}

fcitx5_running() {
  gdbus call --session \
    --dest org.fcitx.Fcitx5 \
    --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.State >/dev/null 2>&1
}

reload_classicui() {
  if ! command -v gdbus >/dev/null 2>&1; then
    printf 'error: 找不到 gdbus，无法热重载 Classic UI 插件\n' >&2
    return 1
  fi

  gdbus call --session \
    --dest org.fcitx.Fcitx5 \
    --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.ReloadAddonConfig \
    classicui >/dev/null
}

reload_fcitx_config() {
  fcitx5_running || return 1
  fcitx5-remote -r >/dev/null 2>&1 || return 1
  reload_classicui
}
