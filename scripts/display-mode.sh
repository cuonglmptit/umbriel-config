#!/bin/sh
set -eu

LAPTOP="eDP-1"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/umbriel-mirror-windows.tsv"
EXT_TF_FILE="${XDG_RUNTIME_DIR:-/tmp}/umbriel-mirror-ext-transform"

EXT="$(umbriel outputs --json | jq -r --arg l "$LAPTOP" '.[] | select(.name != $l) | .name' | head -n 1)"

get_laptop_width() {
    umbriel outputs --json | jq -r --arg l "$LAPTOP" '
        .[] | select(.name == $l) | .logical_size
        | if type == "object" then (.width // .w // 1920)
          elif type == "array" then (.[0] // 1920)
          else 1920 end
    ' 2>/dev/null || echo 1920
}

get_output_transform() {
    umbriel outputs --json | jq -r --arg o "$1" '
        .[] | select(.name == $o) | .transform // "normal"
    ' 2>/dev/null || echo "normal"
}

get_active_ws_index() {
    umbriel workspaces --json | jq -r --arg o "$1" '
        .[] | select(.output == $o and .active == true) | .index
    ' | head -n 1
}

get_output_bars() {
    umbriel layers --json | jq -r --arg out "$1" '
        [.[] | select(.output == $out and (.namespace | startswith("noctalia-bar-")))
         | .namespace | sub("^noctalia-bar-"; "")] | unique[]
    ' 2>/dev/null || true
}

suppress_ext_bar_once() {
    bars="$(get_output_bars "$EXT")"
    [ -n "$bars" ] || bars="default main"
    for b in $bars; do
        noctalia msg bar-layer-set top "$b" "$EXT" >/dev/null 2>&1 || true
        noctalia msg bar-hide "$b" "$EXT" >/dev/null 2>&1 || true
    done

    sleep 0.15

    still_overlay="$(umbriel layers --json | jq -r --arg out "$EXT" '
        any(.[]; .output == $out and .mapped == true and .layer == "overlay" and (.namespace | startswith("noctalia-bar-")))
    ' 2>/dev/null || echo false)"
    if [ "$still_overlay" = "true" ]; then
        noctalia msg bar-layer-set top >/dev/null 2>&1 || true
    fi
}

suppress_ext_bar() {
    suppress_ext_bar_once
    # Theo dõi thêm vài nhịp đề phòng Noctalia tạo lại Bar chậm sau khi đổi output
    (
        for delay in 0.4 0.5 0.6; do
            sleep "$delay"
            pgrep -x wl-mirror >/dev/null 2>&1 || exit 0
            suppress_ext_bar_once
        done
    ) >/dev/null 2>&1 &
}

restore_overlay_bar() {
    noctalia msg bar-layer-set overlay >/dev/null 2>&1 || true
    noctalia msg bar-show >/dev/null 2>&1 || true
}

restore_ext_transform() {
    if [ -n "$EXT" ] && [ -f "$EXT_TF_FILE" ]; then
        saved_tf="$(cat "$EXT_TF_FILE" 2>/dev/null || echo normal)"
        [ -n "$saved_tf" ] || saved_tf="normal"
        cur_tf="$(get_output_transform "$EXT")"
        if [ "$cur_tf" != "$saved_tf" ]; then
            wlr-randr --output "$EXT" --transform "$saved_tf" >/dev/null 2>&1 || true
        fi
        rm -f "$EXT_TF_FILE"
    fi
}

evacuate_ext_windows() {
    ws_json="$(umbriel workspaces --json 2>/dev/null || echo '[]')"
    win_json="$(umbriel windows --json 2>/dev/null || echo '[]')"

    laptop_active_ws="$(printf '%s' "$ws_json" | jq -r --arg l "$LAPTOP" '
        .[] | select(.output == $l and .active == true) | .index
    ' | head -n 1)"
    ext_active_ws="$(printf '%s' "$ws_json" | jq -r --arg ext "$EXT" '
        .[] | select(.output == $ext and .active == true) | .index
    ' | head -n 1)"

    [ -n "$laptop_active_ws" ] || laptop_active_ws=1
    [ -n "$ext_active_ws" ] || ext_active_ws=1

    items="$(printf '%s' "$win_json" | jq -r --arg ext "$EXT" --argjson ws "$ws_json" '
        .[]
        | select(
            ((.output == $ext) or ((.workspace // "") | startswith($ext + ":")))
            and (.app_id != "at.yrlf.wl_mirror")
            and (.pinned != true)
            and (.minimized != true)
            and ((.scratchpad // "") == "")
          )
        | . as $w
        | ($ws | map(select(.id == $w.workspace or ((.output + ":" + .name) == $w.workspace))) | first | .index // 1) as $idx
        | "\($w.id)\t\($idx)"
    ' 2>/dev/null || true)"

    [ -n "$items" ] || return 0

    TAB="$(printf '\t')"
    printf '%s\n' "$items" | while IFS="$TAB" read -r win_id orig_idx; do
        [ -n "$win_id" ] || continue
        printf '%s\t%s\n' "$win_id" "$orig_idx" >> "$STATE_FILE"
        if [ "$orig_idx" = "$ext_active_ws" ]; then
            target_ws="$laptop_active_ws"
        else
            target_ws="$orig_idx"
        fi
        umbriel msg window-focus "$win_id" >/dev/null 2>&1 || true
        umbriel msg window-move-to-workspace-silent "$target_ws" --output "$LAPTOP" >/dev/null 2>&1 || true
    done
}

restore_ext_windows() {
    [ -s "$STATE_FILE" ] || return 0
    win_json="$(umbriel windows --json 2>/dev/null || echo '[]')"
    TAB="$(printf '\t')"

    while IFS="$TAB" read -r win_id orig_idx; do
        [ -n "$win_id" ] || continue
        exists="$(printf '%s' "$win_json" | jq -r --arg id "$win_id" 'any(.[]; .id == $id)' 2>/dev/null || echo false)"
        if [ "$exists" = "true" ]; then
            umbriel msg window-focus "$win_id" >/dev/null 2>&1 || true
            umbriel msg window-move-to-workspace-silent "${orig_idx:-1}" --output "$EXT" >/dev/null 2>&1 || true
        fi
    done < "$STATE_FILE"

    rm -f "$STATE_FILE"
}

if [ -n "$EXT" ]; then
    MENU="$(printf '1. Chỉ màn Laptop\tChỉ hiển thị %s (tắt %s)\n2. Chỉ màn ngoài\tChỉ hiển thị %s (tắt %s)\n3. Extend (Mở rộng)\tDùng cả 2 màn độc lập (%s + %s)\n4. Mirror (Chiếu giống nhau)\tGom cửa sổ về 1 màn, chiếu y hệt và khóa chuột\n5. Sắp xếp màn hình (GUI)\tKéo thả vị trí 2 màn bằng Noctalia\n6. Cài đặt màn hình (GUI)\tĐổi độ phân giải, Hz, scale bằng Noctalia' \
        "$LAPTOP" "$EXT" "$EXT" "$LAPTOP" "$LAPTOP" "$EXT")"
else
    MENU="$(printf '1. Chỉ màn Laptop\tĐang chỉ kết nối %s\n5. Sắp xếp màn hình (GUI)\tMở bảng sắp xếp màn hình Noctalia\n6. Cài đặt màn hình (GUI)\tMở cài đặt hiển thị Noctalia' \
        "$LAPTOP")"
fi

choice="$(printf '%s\n' "$MENU" | noctalia dmenu -p "Chế độ màn hình")" || exit 0

case "$choice" in
    1.*)
        pkill -x wl-mirror 2>/dev/null || true
        rm -f "$STATE_FILE" "$EXT_TF_FILE"
        umbriel msg output-enable "$LAPTOP"
        if [ -n "$EXT" ]; then
            umbriel msg output-disable "$EXT"
        fi
        restore_overlay_bar
        ;;
    2.*)
        if [ -z "$EXT" ]; then
            notify-send "Màn hình" "Chưa phát hiện màn hình ngoài!"
            exit 1
        fi
        pkill -x wl-mirror 2>/dev/null || true
        rm -f "$STATE_FILE"
        umbriel msg output-enable "$EXT"
        sleep 0.2
        restore_ext_transform
        umbriel msg output-disable "$LAPTOP"
        restore_overlay_bar
        ;;
    3.*)
        pkill -x wl-mirror 2>/dev/null || true
        umbriel msg output-enable "$LAPTOP"
        if [ -n "$EXT" ]; then
            umbriel msg output-enable "$EXT"
            sleep 0.3
            restore_ext_transform
            LAPTOP_W="$(get_laptop_width)"
            [ "${LAPTOP_W:-0}" -gt 0 ] 2>/dev/null || LAPTOP_W=1920
            wlr-randr --output "$LAPTOP" --pos 0,0 --output "$EXT" --pos "${LAPTOP_W},0"
            restore_ext_windows
        fi
        restore_overlay_bar
        ;;
    4.*)
        if [ -z "$EXT" ]; then
            notify-send "Màn hình" "Cần cắm màn hình ngoài để Mirror!"
            exit 1
        fi
        pkill -x wl-mirror 2>/dev/null || true

        LAPTOP_WIN="$(umbriel windows --json | jq -r --arg l "$LAPTOP" '
            [.[] | select(.focused == true and ((.output == $l) or ((.workspace // "") | startswith($l + ":"))))] | first | .id // empty
        ' 2>/dev/null || true)"
        if [ -z "$LAPTOP_WIN" ]; then
            LAPTOP_WIN="$(umbriel windows --json | jq -r --arg l "$LAPTOP" '
                [.[] | select(.visible == true and ((.output == $l) or ((.workspace // "") | startswith($l + ":"))))] | first | .id // empty
            ' 2>/dev/null || true)"
        fi

        umbriel msg output-enable "$LAPTOP"
        umbriel msg output-enable "$EXT"
        sleep 0.4

        if [ ! -f "$EXT_TF_FILE" ]; then
            get_output_transform "$EXT" > "$EXT_TF_FILE"
        fi
        laptop_tf="$(get_output_transform "$LAPTOP")"
        ext_tf="$(get_output_transform "$EXT")"

        evacuate_ext_windows

        # Chỉ truyền --transform nếu hướng 2 màn đang khác nhau
        if [ "$ext_tf" != "$laptop_tf" ]; then
            wlr-randr --output "$LAPTOP" --pos 0,0 \
                      --output "$EXT" --pos 10000,0 --transform "$laptop_tf"
        else
            wlr-randr --output "$LAPTOP" --pos 0,0 \
                      --output "$EXT" --pos 10000,0
        fi
        sleep 0.2

        setsid -f wl-mirror --fullscreen-output "$EXT" --fullscreen "$LAPTOP" >/dev/null 2>&1

        i=0
        MIRROR_ID=""
        while [ "$i" -lt 20 ]; do
            MIRROR_ID="$(umbriel windows --json | jq -r '.[] | select(.app_id == "at.yrlf.wl_mirror") | .id' | head -n 1)"
            [ -n "$MIRROR_ID" ] && break
            sleep 0.1
            i=$((i + 1))
        done

        if [ -n "$MIRROR_ID" ]; then
            ON_EXT="$(umbriel windows --json | jq -r --arg id "$MIRROR_ID" --arg ext "$EXT" '
                .[] | select(.id == $id) | ((.output == $ext) or ((.workspace // "") | startswith($ext + ":")))
            ' 2>/dev/null || echo false)"

            if [ "$ON_EXT" != "true" ]; then
                EXT_WS="$(get_active_ws_index "$EXT")"
                umbriel msg window-focus "$MIRROR_ID"
                umbriel msg window-move-to-workspace "${EXT_WS:-1}" --output "$EXT"
                sleep 0.1
            fi

            IS_FS="$(umbriel windows --json | jq -r --arg id "$MIRROR_ID" '
                .[] | select(.id == $id) | .fullscreen
            ' 2>/dev/null || echo false)"
            if [ "$IS_FS" != "true" ]; then
                umbriel msg window-focus "$MIRROR_ID"
                umbriel msg window-toggle-fullscreen
            fi
        fi

        suppress_ext_bar

        if [ -n "$LAPTOP_WIN" ]; then
            umbriel msg window-focus-warp "$LAPTOP_WIN" >/dev/null 2>&1 || true
        else
            LAPTOP_WS="$(get_active_ws_index "$LAPTOP")"
            umbriel msg workspace-switch "${LAPTOP_WS:-1}" --output "$LAPTOP" >/dev/null 2>&1 || true
        fi
        ;;
    5.*)
        noctalia msg panel-toggle prponkshe/umbriel-displays:arrange
        ;;
    6.*)
        noctalia msg panel-toggle prponkshe/umbriel-displays:panel
        ;;
esac
