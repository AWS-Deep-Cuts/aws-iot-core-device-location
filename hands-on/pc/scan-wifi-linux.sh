#!/bin/bash
set -euo pipefail

# AWS Deep Cuts - AWS IoT Core Device Location ハンズオン
# あなたの PC で周囲の Wi-Fi を測り、測定値を wifi.json に保存します。AWS は呼び出しません。
#
# 使い方（PC の作業フォルダ ~/iotdl-handson で実行します）:
#   sudo bash ./scan-wifi-linux.sh --with-ip   iw で受信信号強度を dBm で直接取得する
#   bash ./scan-wifi-linux.sh --with-ip        nmcli の SIGNAL の百分率から dBm を近似する
#   --with-ip は任意です。付けると、手順 4-3 で使う PC の IP アドレスを ip.json に保存します。
#   環境変数 MAX で、残すアクセスポイントの数を変えられます。既定は 10 台です。
#
# スクリプトが行うこと:
#   1. アクセスポイントの MAC アドレス（BSSID）と信号の強さを取り出す
#   2. 信号の強さを受信信号強度（dBm）に換算する
#      iw   : dBm を直接表示するため、換算しない
#      nmcli: SIGNAL は百分率。NetworkManager の nm_wifi_utils_level_to_quality() は
#             dBm を -100〜-40 に丸めて 0〜100 % に変換しているため、
#             dBm ≒ SIGNAL × 0.6 − 100 で近似する。-40 dBm より強い値は区別できない
#   3. ローカル管理アドレスを除く。ローカル管理アドレスは、機器が自分で決めた MAC アドレスで、
#      スマートフォンのテザリングなどで使われることが多い。送るアドレスを減らすために除く
#   4. 受信信号強度の強い順に、最大 MAX 台を残す
#   5. SSID（ネットワークの名前）は書き出さない
#
# wifi.json は、近隣のアクセスポイントの MAC アドレスを含みます。公開しないでください。

MAX="${MAX:-10}"
WITH_IP=0
for arg in "$@"; do
  case "${arg}" in
    --with-ip) WITH_IP=1 ;;
    -h|--help) sed -n '4,11p' "$0"; exit 0 ;;
    *) echo "❌ Error: 不明な引数です: ${arg}" >&2; exit 2 ;;
  esac
done
if ! [[ "${MAX}" =~ ^[0-9]+$ ]] || (( MAX < 1 )); then
  echo "❌ Error: MAX には 1 以上の整数を指定してください。" >&2
  exit 2
fi

OUT_DIR="$(pwd)"
WIFI_FILE="${OUT_DIR}/wifi.json"
IP_FILE="${OUT_DIR}/ip.json"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - 周囲の Wi-Fi を測る（Linux）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1 行に「MAC アドレス 受信信号強度」を書いた一覧を ${TMP}/raw.txt に作る
METHOD=""
: > "${TMP}/raw.txt"

if [[ "${EUID}" -eq 0 ]] && command -v iw >/dev/null; then
  IFACE=$(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2; exit }')
  if [[ -n "${IFACE}" ]]; then
    METHOD="iw（受信信号強度を dBm で直接取得）"
    echo "測定の方法: ${METHOD}"
    echo "無線のインターフェース: ${IFACE}"
    # 別の処理がスキャン中だと失敗することがあるため、2 秒おきに 3 回まで試す
    SCAN_OK=0
    for _ in 1 2 3; do
      if iw dev "${IFACE}" scan > "${TMP}/iw.txt" 2>/dev/null; then
        SCAN_OK=1
        break
      fi
      sleep 2
    done
    if [[ "${SCAN_OK}" == "1" ]]; then
      # 「BSS 00:00:5e:00:53:01(on wlan0)」の行で MAC アドレスを、続く「signal: -52.00 dBm」の行で dBm を読む
      awk '
        /^BSS / { mac = substr($2, 1, 17); next }
        $1 == "signal:" && mac != "" {
          v = $2 + 0
          r = (v < 0) ? int(v - 0.5) : int(v + 0.5)
          print mac, r
          mac = ""
        }
      ' "${TMP}/iw.txt" > "${TMP}/raw.txt"
    else
      echo "  ⚠️  iw でスキャンできませんでした。nmcli で測ります。"
      METHOD=""
    fi
  fi
fi

if [[ -z "${METHOD}" ]]; then
  if ! command -v nmcli >/dev/null; then
    echo "❌ Error: nmcli コマンドが見つかりません。" >&2
    echo "   NetworkManager を使っていない場合は、sudo を付けて実行し、iw で測ってください。" >&2
    exit 1
  fi
  METHOD="nmcli（SIGNAL の百分率から dBm ≒ SIGNAL × 0.6 − 100 で近似）"
  echo "測定の方法: ${METHOD}"
  # -t の出力では、MAC アドレスの「:」が「\:」と書かれる。「\:」を「-」に置き換えてから区切る
  if ! nmcli -t -f BSSID,SIGNAL device wifi list --rescan yes > "${TMP}/nmcli.txt" 2>/dev/null; then
    nmcli -t -f BSSID,SIGNAL device wifi list > "${TMP}/nmcli.txt" 2>/dev/null || true
  fi
  sed 's/\\:/-/g' "${TMP}/nmcli.txt" | awk -F: '
    NF >= 2 && $1 != "" && $2 ~ /^[0-9]+$/ {
      mac = $1
      gsub("-", ":", mac)
      v = $2 * 0.6 - 100
      r = (v < 0) ? int(v - 0.5) : int(v + 0.5)
      print mac, r
    }
  ' > "${TMP}/raw.txt"
fi

# 形の確認、大文字・コロン区切りへの統一、ローカル管理アドレスの除外、範囲の制限
: > "${TMP}/clean.txt"
EXCLUDED=0
while read -r mac rss; do
  mac="${mac^^}"
  [[ "${mac}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || continue
  [[ "${rss}" =~ ^-?[0-9]+$ ]] || continue
  # 最初のオクテットの下から 2 ビット目が 1 のアドレスは、ローカル管理アドレス
  if (( (16#${mac:0:2} & 2) != 0 )); then
    EXCLUDED=$((EXCLUDED + 1))
    continue
  fi
  if (( rss > 0 )); then rss=0; fi
  if (( rss < -128 )); then rss=-128; fi
  echo "${mac} ${rss}" >> "${TMP}/clean.txt"
done < "${TMP}/raw.txt"

# 強い順に並べ、同じ MAC アドレスは最初の 1 つだけを残し、MAX 台まで残す
sort -k2,2nr "${TMP}/clean.txt" | awk '!seen[$1]++' | head -n "${MAX}" > "${TMP}/top.txt" || true
COUNT=$(wc -l < "${TMP}/top.txt" | tr -d ' ')

echo ""
if [[ "${COUNT}" == "0" ]]; then
  echo "❌ アクセスポイントが見つかりませんでした。wifi.json は作成していません。" >&2
  echo "   測定の方法: ${METHOD}" >&2
  echo "   Wi-Fi が有効かを確かめてください。" >&2
  if [[ "${EXCLUDED}" != "0" ]]; then
    echo "   除いたローカル管理アドレス: ${EXCLUDED} 台" >&2
  fi
  exit 1
fi

# wifi.json を書き出す（1 行に 1 つのキー。SSID は書き出さない）
awk '
  BEGIN { print "[" }
  {
    if (NR > 1) print "  },"
    print "  {"
    printf "    \"MacAddress\": \"%s\",\n", $1
    printf "    \"Rss\": %d\n", $2
  }
  END { print "  }"; print "]" }
' "${TMP}/top.txt" > "${TMP}/wifi.json"
mv -f -- "${TMP}/wifi.json" "${WIFI_FILE}"
chmod 600 "${WIFI_FILE}"

echo "wifi.json に保存したアクセスポイント: ${COUNT} 台（MAC アドレスの前半 4 オクテットを伏せて表示）"
while read -r mac rss; do
  echo "  **:**:**:**:${mac:12:5}  ${rss} dBm"
done < "${TMP}/top.txt"
if [[ "${EXCLUDED}" != "0" ]]; then
  echo "除いたローカル管理アドレス: ${EXCLUDED} 台"
fi
echo "保存先: ${WIFI_FILE}"

if [[ "${WITH_IP}" == "1" ]]; then
  echo ""
  # $(...) は末尾の改行を落とす。空の場合と、IP アドレスではない応答の場合は、ip.json を作成しない
  ip=$(curl -s https://checkip.amazonaws.com || true)
  if [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    printf '{"IpAddress": "%s"}\n' "${ip}" > "${TMP}/ip.json"
    mv -f -- "${TMP}/ip.json" "${IP_FILE}"
    chmod 600 "${IP_FILE}"
    echo "PC の IP アドレスを保存しました: ${IP_FILE}"
  else
    echo "⚠️  IP アドレスを取得できませんでした。手順 4-3 は行わずに進めてください。"
  fi
fi

# sudo で実行した場合、作成したファイルは root の所有になる。実行した利用者の所有に戻す
if [[ -n "${SUDO_UID:-}" ]]; then
  for f in "${WIFI_FILE}" "${IP_FILE}"; do
    if [[ -e "${f}" ]]; then
      chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${f}"
    fi
  done
fi

echo ""
echo "⚠️  wifi.json は、近隣のアクセスポイントの MAC アドレスを含みます。公開しないでください。"
