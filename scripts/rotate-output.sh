#!/bin/sh
set -eu

TRANSFORM="${1:-normal}"
LAPTOP="eDP-1"

get_output_bars() {
    umbriel layers --json | jq -r --arg out "$1" '
        [.[] | select(.output == $out and (.namespace | startswith("noctalia-bar-")))
         | .namespace | sub("^noctalia-bar-"; "")] | unique[]
    ' 2>/dev/null || true
}

suppress_ext_bar_once() {
    ext="$1"
    bars="$(get_output_bars "$ext")"
    [ -n "$bars" ] || bars="default main"
    for b in $bars; do
        noctalia msg bar-layer-set top "$b" "$ext" >/dev/null 2>&1 || true
        noctalia msg bar-hide "$b" "$ext" >/dev/null 2>&1 || true
    done

    sleep 0.15

    still_overlay="$(umbriel layers --json | jq -r --arg out "$ext" '
        any(.[]; .output == $out and .mapped == true and .layer == "overlay" and (.namespace | startswith("noctalia-bar-")))
    ' 2>/dev/null || echo false)"
    if [ "$still_overlay" = "true" ]; then
        noctalia msg bar-layer-set top >/dev/null 2>&1 || true
    fi
}

suppress_ext_bar() {
    ext="$1"
    suppress_ext_bar_once "$ext"
    (
        for delay in 0.4 0.5 0.6; do
            sleep "$delay"
            pgrep -x wl-mirror >/dev/null 2>&1 || exit 0
            suppress_ext_bar_once "$ext"
        done
    ) >/dev/null 2>&1 &
}

OUT_JSON="$(umbriel outputs --json)"

# Nếu đang chạy Mirror: xoay ĐỒNG THỜI cả Laptop và màn ngoài, mở lại wl-mirror và tắt Bar màn ngoài
if pgrep -x wl-mirror >/dev/null 2>&1; then
    EXT="$(printf '%s' "$OUT_JSON" | jq -r --arg l "$LAPTOP" '.[] | select(.name != $l and .enabled == true) | .name' | head -n 1)"

    if [ -n "$EXT" ]; then
        CUR_WIN="$(umbriel windows --json | jq -r --arg l "$LAPTOP" '
            [.[] | select(.focused == true and .app_id != "at.yrlf.wl_mirror" and ((.output == $l) or ((.workspace // "") | startswith($l + ":"))))]
            | first | .id // empty
        ' 2>/dev/null || true)"
        if [ -z "$CUR_WIN" ]; then
            CUR_WIN="$(umbriel windows --json | jq -r --arg l "$LAPTOP" '
                [.[] | select(.visible == true and .app_id != "at.yrlf.wl_mirror" and ((.output == $l) or ((.workspace // "") | startswith($l + ":"))))]
                | first | .id // empty
            ' 2>/dev/null || true)"
        fi

        pkill -x wl-mirror 2>/dev/null || true
        wlr-randr --output "$LAPTOP" --pos 0,0 --transform "$TRANSFORM" \
                  --output "$EXT" --pos 10000,0 --transform "$TRANSFORM"
        sleep 0.25

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
                EXT_WS="$(umbriel workspaces --json | jq -r --arg o "$EXT" '.[] | select(.output == $o and .active == true) | .index' | head -n 1)"
                umbriel msg window-focus "$MIRROR_ID"
                umbriel msg window-move-to-workspace "${EXT_WS:-1}" --output "$EXT"
                sleep 0.1
            fi

            IS_FS="$(umbriel windows --json | jq -r --arg id "$MIRROR_ID" '.[] | select(.id == $id) | .fullscreen' 2>/dev/null || echo false)"
            if [ "$IS_FS" != "true" ]; then
                umbriel msg window-focus "$MIRROR_ID"
                umbriel msg window-toggle-fullscreen
            fi
        fi

        # Ẩn/hạ lại Bar của màn ngoài sau khi vừa xoay
        suppress_ext_bar "$EXT"

        if [ -n "$CUR_WIN" ]; then
            umbriel msg window-focus-warp "$CUR_WIN" >/dev/null 2>&1 || true
        else
            LAPTOP_WS="$(umbriel workspaces --json | jq -r --arg o "$LAPTOP" '.[] | select(.output == $o and .active == true) | .index' | head -n 1)"
            umbriel msg workspace-switch "${LAPTOP_WS:-1}" --output "$LAPTOP" >/dev/null 2>&1 || true
        fi
        exit 0
    fi
fi

# Chế độ bình thường (1 màn hoặc Extend): chỉ xoay màn hình đang focus
FOCUSED="$(printf '%s' "$OUT_JSON" | jq -r '
    ([.[] | select(.focused == true and .enabled == true)]
     + [.[] | select(.enabled == true)])
    | first | .name // empty
')"

[ -n "$FOCUSED" ] || exit 0
wlr-randr --output "$FOCUSED" --transform "$TRANSFORM"

# Tự chỉnh lại mép màn bên phải nếu vừa xoay màn trái (eDP-1) ở chế độ Extend ngang
if [ "$FOCUSED" = "$LAPTOP" ]; then
    sleep 0.15
    OUT_JSON="$(umbriel outputs --json)"
    EXT="$(printf '%s' "$OUT_JSON" | jq -r --arg l "$LAPTOP" '.[] | select(.name != $l and .enabled == true) | .name' | head -n 1)"
    if [ -n "$EXT" ]; then
        EXT_X="$(printf '%s' "$OUT_JSON" | jq -r --arg o "$EXT" '
            .[] | select(.name == $o) | .position
            | if type == "object" then (.x // 0) elif type == "array" then (.[0] // 0) else 0 end
        ')"
        EXT_Y="$(printf '%s' "$OUT_JSON" | jq -r --arg o "$EXT" '
            .[] | select(.name == $o) | .position
            | if type == "object" then (.y // 0) elif type == "array" then (.[1] // 0) else 0 end
        ')"
        if [ "$EXT_Y" = "0" ] && [ "${EXT_X:-0}" -gt 0 ] 2>/dev/null; then
            NEW_W="$(printf '%s' "$OUT_JSON" | jq -r --arg l "$LAPTOP" '
                .[] | select(.name == $l) | .logical_size
                | if type == "object" then (.width // .w // 0) elif type == "array" then (.[0] // 0) else 0 end
            ')"
            if [ "${NEW_W:-0}" -gt 0 ] 2>/dev/null; then
                wlr-randr --output "$LAPTOP" --pos 0,0 --output "$EXT" --pos "${NEW_W},0"
            fi
        fi
    fi
fi
