#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - AWS IoT Core Device Location ハンズオンの後片付け
#
# このハンズオンでは AWS のリソースを作成していないため、AWS の側に削除するものはありません。
# 料金は GetPositionEstimate を呼び出したときだけ発生し、呼び出しをやめた時点で発生しなくなります。
# このスクリプトは、料金を止めるためではなく、あなたの居場所に結び付くファイルを削除するために実行します。
#   [1/3] CloudShell の work フォルダ（測定値と応答の GeoJSON）を削除する
#   [2/3] ホームディレクトリにアップロードしたまま残ったファイルを確かめる（自動では削除しない）
#   [3/3] handson.env を削除する
# 何度実行しても、同じ結果になります。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ENV_FILE="${SCRIPT_DIR}/handson.env"
readonly EXPECTED_WORK_DIR="${SCRIPT_DIR}/work"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - AWS IoT Core Device Location 後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

WORK_DIR="${EXPECTED_WORK_DIR}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi
WARN=0

# ─── [1/3] work フォルダ ─────────────────────────────────────
echo "[1/3] CloudShell の work フォルダを削除..."
# handson.env が書き換えられていても、hands-on/work 以外のフォルダは削除しない
if [[ "${WORK_DIR}" != "${EXPECTED_WORK_DIR}" ]]; then
  echo "  ⚠️  handson.env の WORK_DIR が ${EXPECTED_WORK_DIR} と異なるため、削除しません: ${WORK_DIR}"
  WARN=1
elif [[ -d "${WORK_DIR}" ]]; then
  # ファイルの中身は表示せず、名前だけを表示する
  FILES=$(find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  if [[ -n "${FILES}" ]]; then
    while IFS= read -r name; do
      echo "  削除: ${name}"
    done <<<"${FILES}"
  fi
  rm -rf -- "${WORK_DIR}"
  echo "  削除: ${WORK_DIR}"
else
  echo "  対象なし"
fi
echo ""

# ─── [2/3] ホームディレクトリに残ったファイル ─────────────────────
echo "[2/3] ホームディレクトリに残ったファイルを確認..."
# 手順 4-1 でアップロードしたファイルは、mv で work フォルダに移しているはず。
# 同じ名前の別のファイルを削除しないように、ここでは削除せず、削除のコマンドだけを表示する。
LEFT_FILES=()
for f in "${HOME}/wifi.json" "${HOME}/ip.json"; do
  if [[ -e "${f}" ]]; then
    LEFT_FILES+=("${f}")
  fi
done
if (( ${#LEFT_FILES[@]} > 0 )); then
  for f in "${LEFT_FILES[@]}"; do
    echo "  ⚠️  残っています: ${f}"
  done
  echo "     ハンズオンでアップロードしたファイルであれば、次のコマンドで削除してください。"
  for f in "${LEFT_FILES[@]}"; do
    echo "     rm ~/$(basename "${f}")"
  done
  WARN=1
else
  echo "  なし"
fi
echo ""

# ─── [3/3] handson.env ─────────────────────────────────────
echo "[3/3] handson.env を削除..."
if [[ -f "${ENV_FILE}" ]]; then
  rm -f -- "${ENV_FILE}"
  echo "  削除: ${ENV_FILE}"
else
  echo "  対象なし"
fi
echo ""

# ─── 残ったものの確認 ───────────────────────────────────────
echo "残っているファイルを確認..."
LEFT=0
if [[ -e "${EXPECTED_WORK_DIR}" ]]; then
  echo "  ⚠️  work フォルダが残っています: ${EXPECTED_WORK_DIR}"
  LEFT=1
fi
if [[ -e "${ENV_FILE}" ]]; then
  echo "  ⚠️  handson.env が残っています: ${ENV_FILE}"
  LEFT=1
fi
if [[ "${LEFT}" == "1" ]]; then
  WARN=1
else
  echo "  なし"
fi
echo ""

echo "AWS 側に削除するリソースはありません。"
echo "PC の作業フォルダ iotdl-handson は、PC でフォルダごと削除してください。"
echo "  Windows（PowerShell）: Set-Location \$HOME"
echo "                         Remove-Item -Recurse -Force \"\$HOME\\iotdl-handson\""
echo "  Linux:                 cd ~ && rm -rf ~/iotdl-handson"
echo ""

if [[ "${WARN}" == "1" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  確認が必要なファイルがあります。⚠️ の行を確認し、表示されたコマンドを実行してから、"
  echo "   もう一度 bash ./cleanup.sh を実行してください。"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 後片付けが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
