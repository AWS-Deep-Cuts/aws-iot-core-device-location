#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - AWS IoT Core Device Location ハンズオンの事前準備
#
# このハンズオンでは、AWS のリソースを作成しません。GetPositionEstimate は、AWS に登録した機器のような
# AWS のリソースを指定せずに、測定値だけを送って呼び出す API です（botocore の iotwireless 2020-11-22 の
# GetPositionEstimateRequest には、必須の項目もリソースの ID を取る項目もありません）。
# 位置の推定そのものは、README の手順で 1 コマンドずつ実行します。
#
# このスクリプトが行うのは、次の 4 つだけです。料金のかかる呼び出しはしません。
#   [1/4] 必要なコマンド（aws・python3・curl・jq）があるかを確かめる
#   [2/4] AWS CLI が信頼度の指定（--advanced-configuration）に対応しているかを確かめる
#   [3/4] AWS アカウントを確かめる
#   [4/4] 測定値と応答を保存する work フォルダと、変数を保存する handson.env を作成する
#
# シリーズの他のハンズオンは、作成したリソースの ID を resource-ids.env に保存します。
# このハンズオンでは AWS のリソースを作成しないため、保存するのは CloudShell の変数だけです。
# そのため、ファイルの名前を handson.env にしています。

readonly REGION="ap-northeast-1"   # endpoints.json の api.iotwireless と、Price List の位置の単価が東京にある
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ENV_FILE="${SCRIPT_DIR}/handson.env"
readonly WORK_DIR="${SCRIPT_DIR}/work"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - AWS IoT Core Device Location 事前準備"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/4] 前提の確認 ─────────────────────────────────────────
echo "[1/4] 前提を確認..."
if [[ -f "${ENV_FILE}" ]]; then
  echo "❌ Error: ${ENV_FILE} が既に存在します。前回の準備が残っています。" >&2
  echo "   続きから進める場合は、source ./handson.env を実行してください。" >&2
  echo "   最初からやり直す場合は、先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
for cmd in aws python3 curl; do
  command -v "${cmd}" >/dev/null || { echo "❌ Error: ${cmd} コマンドが見つかりません。" >&2; exit 1; }
done
# jq は、手順 4 と手順 6 で JSON を検査・加工するために使う。自動ではインストールしない
if ! command -v jq >/dev/null; then
  echo "❌ Error: jq コマンドが見つかりません。" >&2
  echo "   sudo dnf install -y jq を実行してから、もう一度 bash ./setup.sh を実行してください。" >&2
  exit 1
fi
echo "  aws・python3・curl・jq があります"
echo ""

# ─── [2/4] AWS CLI の確認 ──────────────────────────────────────
echo "[2/4] AWS CLI を確認..."
echo "  $(aws --version 2>&1)"
# 信頼度にわざと範囲外の 30 を指定する。対応している AWS CLI は、リクエストを AWS に送る前に
# 入力を検査し、ParamValidation の「valid min value: 50」で止まる。止まったリクエストは
# AWS に送られないため、料金はかからない。出力先のファイルには /dev/null を指定する。
# 古い AWS CLI は --advanced-configuration を知らないため、「Unknown options」などで止まる。
CHECK_OUTPUT=$(aws iotwireless get-position-estimate /dev/null \
  --advanced-configuration 'WiFiCellular={ConfidencePercent=30}' \
  --region "${REGION}" 2>&1 || true)
if grep -q 'valid min value: 50' <<<"${CHECK_OUTPUT}"; then
  echo "  ✅ この AWS CLI は信頼度の指定（--advanced-configuration）に対応しています"
else
  echo "❌ Error: この AWS CLI は信頼度の指定（--advanced-configuration）に対応していません。" >&2
  echo "   v2.34.35 以降が必要です。" >&2
  echo "   README の「前提条件」の手順で、ホームディレクトリに最新版の AWS CLI をインストールしてください。" >&2
  exit 1
fi
echo ""

# ─── [3/4] AWS アカウントの確認 ─────────────────────────────────
echo "[3/4] AWS アカウントを確認..."
# GetCallerIdentity には IAM の権限が要らない
# （botocore の sts 2011-06-15 の説明文: "No permissions are required to perform this operation."）
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "❌ Error: AWS の認証情報を取得できません。CloudShell で実行しているか確認してください。" >&2
  exit 1
}
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION}"
echo ""

# ─── [4/4] 作業用のフォルダの作成 ───────────────────────────────
echo "[4/4] 作業用のフォルダを作成..."
# work フォルダには、あなたの居場所に結び付く測定値と応答を保存する。
# あなただけが読み書きできるように、権限を 700 にする。既にあれば、そのまま使う。
mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"
cat > "${ENV_FILE}" <<EOF
# AWS Deep Cuts IoT Core Device Location - CloudShell の変数（setup.sh が作成。cleanup.sh が削除します）
REGION="${REGION}"
HANDSON_DIR="${SCRIPT_DIR}"
WORK_DIR="${WORK_DIR}"
EOF
echo "  CloudShell の work フォルダ: ${WORK_DIR}"
echo "  変数の保存先:               ${ENV_FILE}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "AWS のリソースは作成していません。"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "次のステップ: 次のコマンドで変数を読み込んでから、README の手順 1 の「確かめること」に進んでください。"
echo "  source ./handson.env"
