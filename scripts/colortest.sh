#!/bin/sh
# 色の見比べ用の見本を端末に流す（docs/design.md「描画と解像度」の「色」）。
# Mac の Ghostty と、Mobile-SSH-Client---Split-Keyboard（tmux の外と中）で、同じものを流して見比べる。
# POSIX sh と printf だけで動く（接続先に何も入れなくてよい。1 行が 54 桁に収まる）。
#
# 使い方: scripts/colortest.sh [all|16|256|true|claude|bold]
#
# 見るところ:
#   16 色    アプリの palette と Ghostty の theme が同じ色か。明るい色（9x・10x）が薄く見えないか
#   256 色   立方体（16〜231）と灰色（232〜255）が、Ghostty と同じ標準の色か
#   true     帯がなめらか（段が見えない）か。tmux の中だけ段が見えたら、256 色に丸められている
#   claude   Claude Code の色に近い見本（オレンジなど）が、Ghostty と同じ色味か
#   bold     通常と太字で、色（bold-is-bright）と文字の太さ（font-thicken）が Ghostty と同じか

ESC=$(printf '\033')
RESET="${ESC}[0m"

# 見出し（太字）
title() {
    printf '%s\n' "${ESC}[1m$1${RESET}"
}

# 色の見本 1 つ。引数: SGR の番号 表示する番号 後ろの文字
cell() {
    printf '%s[%sm%2s%s %s' "$ESC" "$1" "$2" "$3" "$RESET"
}

# 16 色。通常 0〜7（文字 30〜37・背景 40〜47）と明るい 8〜15（文字 90〜97・背景 100〜107）
sixteen() {
    title "== 16 色"
    printf 'fg  '
    for n in 0 1 2 3 4 5 6 7; do cell "$((30 + n))" "$n" Ab; done
    printf '\nfg+ '
    for n in 0 1 2 3 4 5 6 7; do cell "$((90 + n))" "$((n + 8))" Ab; done
    printf '\nbg  '
    for n in 0 1 2 3 4 5 6 7; do cell "$((40 + n))" "$n" '  '; done
    printf '\nbg+ '
    for n in 0 1 2 3 4 5 6 7; do cell "$((100 + n))" "$((n + 8))" '  '; done
    printf '\n'
}

# 256 色（48;5;N と 38;5;N）。0〜15、6x6x6 の立方体 16〜231（1 行 36 色）、灰色 232〜255
two_fifty_six() {
    title "== 256 色 (48;5;N / 38;5;N)"
    printf '0-15    '
    n=0
    while [ "$n" -lt 16 ]; do
        printf '%s' "${ESC}[48;5;${n}m  ${RESET}"
        n=$((n + 1))
    done
    printf '\n16-231 (6x6x6)\n'
    row=0
    while [ "$row" -lt 6 ]; do
        n=$((16 + row * 36))
        end=$((n + 36))
        while [ "$n" -lt "$end" ]; do
            printf '%s' "${ESC}[48;5;${n}m ${RESET}"
            n=$((n + 1))
        done
        printf '\n'
        row=$((row + 1))
    done
    printf '232-255 '
    n=232
    while [ "$n" -lt 256 ]; do
        printf '%s' "${ESC}[48;5;${n}m ${RESET}"
        n=$((n + 1))
    done
    printf '\n文字    '
    for n in 196 208 220 46 51 21 201 244; do printf '%s' "${ESC}[38;5;${n}m${n} ${RESET}"; done
    printf '\n'
}

# 1 つの成分を 0 から 255 へ 48 段で増やす帯。引数: 名前 R G B（増やす成分は 1、増やさない成分は 0）
ramp() {
    printf '%s ' "$1"
    i=0
    while [ "$i" -lt 48 ]; do
        v=$((i * 255 / 47))
        printf '%s' "${ESC}[48;2;$(($2 * v));$(($3 * v));$(($4 * v))m ${RESET}"
        i=$((i + 1))
    done
    printf '\n'
}

# true color（48;2;R;G;B と 38;2;R;G;B）。段が見えたら 256 色に丸められている
true_color() {
    title "== true color (48;2;R;G;B)"
    ramp R 1 0 0
    ramp G 0 1 0
    ramp B 0 0 1
    ramp '灰' 1 1 1
    printf '虹 '
    i=0
    while [ "$i" -lt 48 ]; do
        # 色相を 6 区間に分ける（1 区間 8 マス）
        t=$(((i % 8) * 255 / 7))
        case $((i / 8)) in
            0) r=255; g=$t; b=0 ;;
            1) r=$((255 - t)); g=255; b=0 ;;
            2) r=0; g=255; b=$t ;;
            3) r=0; g=$((255 - t)); b=255 ;;
            4) r=$t; g=0; b=255 ;;
            *) r=255; g=0; b=$((255 - t)) ;;
        esac
        printf '%s' "${ESC}[48;2;${r};${g};${b}m ${RESET}"
        i=$((i + 1))
    done
    printf '\n文字 '
    i=0
    while [ "$i" -lt 48 ]; do
        v=$((i * 255 / 47))
        printf '%s' "${ESC}[38;2;255;${v};0mx${RESET}"
        i=$((i + 1))
    done
    printf '\n'
}

# 色の四角（背景）と、その色の文字を並べる。引数: R G B 説明
swatch() {
    printf '%s %s\n' "${ESC}[48;2;$1;$2;$3m   ${RESET}${ESC}[38;2;$1;$2;$3m ### ${RESET}" "$4"
}

# Claude Code の色に近い見本（true color の指定）。256 色の近い色に丸められると、くすんで見える
claude() {
    title "== Claude Code に近い色 (38;2;R;G;B)"
    swatch 215 119 87 'orange 215,119,87'
    swatch 235 159 127 'light orange 235,159,127'
    swatch 177 185 249 'periwinkle 177,185,249'
    swatch 78 186 101 'green 78,186,101'
    swatch 255 107 128 'red 255,107,128'
    swatch 255 193 7 'yellow 255,193,7'
    swatch 153 153 153 'gray 153,153,153'
    printf '%s\n' "${ESC}[48;2;215;119;87m${ESC}[38;2;255;255;255m Claude Code ${RESET} white on orange"
}

# 太字と通常。bold-is-bright が true なら太字の 0〜7 が 8〜15 の色になる（true color と既定の色は変わらない）
bold() {
    title "== 太字と通常 (1m)"
    printf '通常   '
    for n in 0 1 2 3 4 5 6 7; do printf '%s' "${ESC}[$((30 + n))mText ${RESET}"; done
    printf '\n太字   '
    for n in 0 1 2 3 4 5 6 7; do printf '%s' "${ESC}[1;$((30 + n))mText ${RESET}"; done
    printf '\n明るい '
    for n in 0 1 2 3 4 5 6 7; do printf '%s' "${ESC}[$((90 + n))mText ${RESET}"; done
    printf '\n256色 1;38;5;1 と 38;5;9: '
    printf '%s' "${ESC}[1;38;5;1mText ${RESET}${ESC}[38;5;9mText ${RESET}"
    printf '\ntrue 太字と通常 (同じ色): '
    printf '%s' "${ESC}[1;38;2;205;49;49mText ${RESET}${ESC}[38;2;205;49;49mText ${RESET}"
    printf '\n既定色 太字と通常: '
    printf '%s' "${ESC}[1mText ${RESET}${ESC}[0mText ${RESET}"
    printf '\n文字の太さ (font-thicken)\n'
    printf '%s\n' "通常 Hamburgefonstiv 0123456789 日本語"
    printf '%s\n' "${ESC}[1m太字 Hamburgefonstiv 0123456789 日本語${RESET}"
}

case "${1:-all}" in
    16) sixteen ;;
    256) two_fifty_six ;;
    true) true_color ;;
    claude) claude ;;
    bold) bold ;;
    all)
        sixteen
        printf '\n'
        two_fifty_six
        printf '\n'
        true_color
        printf '\n'
        claude
        printf '\n'
        bold
        ;;
    *)
        printf 'usage: %s [all|16|256|true|claude|bold]\n' "$0" >&2
        exit 2
        ;;
esac
printf '%s' "$RESET"
