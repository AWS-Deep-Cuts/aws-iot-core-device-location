#!/usr/bin/env python3
"""AWS Deep Cuts - AWS IoT Core Device Location ハンズオンの答え合わせ。

使い方:
    python3 "${HANDSON_DIR}/score.py" <応答の GeoJSON> [<応答の GeoJSON> ...]

- AWS を呼び出しません。ファイルに何も書きません。
- 実際の位置の緯度と経度を、画面に表示しない形で尋ねます。シェルの履歴に残さないため、
  引数や環境変数では受け取りません。
- 推定位置の座標も、実際の位置の座標も、画面に表示しません。表示するのは、精度・信頼度・
  ずれ・方角・ずれと精度の比・円の中か外かだけです。方角と距離だけでは、どちらの座標も分かりません。
- 応答の GeoJSON の項目の名前と単位は、API の仕様に書かれていません。そのため、このスクリプトは
  項目の名前を探して読みます。
  - 座標: type が Point の coordinates、Feature の geometry.coordinates、FeatureCollection の
    最初の Feature の geometry.coordinates。GeoJSON の決まりどおり「経度、緯度」の順とみなします。
    緯度とみなした値の絶対値が 90 を超える場合は、順序が逆と判断して入れ替えます。
  - 精度: properties（無ければ最上位）の数値の項目のうち、名前に horizontalaccuracy を含むもの。
    無ければ accuracy を含むもの。大文字と小文字は区別しません。
  - 信頼度: 名前に confidence を含む数値の項目。horizontal を含むものを優先します。
- 4 つ以上のファイルを渡されたときは、README の答え合わせ表の順に並べ替えます。
  3 つ以下のときは、渡された順に表示します。
- cloudshell-ip-2.geojson（手順 2-4）と check-*.geojson（手順 5-3）は、表に含めません。
"""

import getpass
import json
import math
import os
import sys
import unicodedata

# 答え合わせ表の順序。ファイル名（拡張子を除く）→ 手順の番号
TABLE_ORDER = [
    ("cloudshell-ip", "2-2"),
    ("wifi-68", "4-2"),
    ("pc-ip", "4-3"),
    ("wifi-50", "5-1 の 50"),
    ("wifi-95", "5-1 の 95"),
    ("wifi-top1", "6-1"),
    ("wifi-top3", "6-2"),
    ("example-mac", "6-3"),
]
STEP_OF = dict(TABLE_ORDER)
ORDER_OF = {name: i for i, (name, _) in enumerate(TABLE_ORDER)}
# あなたの居場所の推定ではないため、ずれ・方角・比・円の中か外かを表示しないファイル
NOT_YOUR_LOCATION = {"cloudshell-ip", "example-mac"}
EARTH_RADIUS_M = 6371000.0
DIRECTIONS = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]
DASH = "—"


def stem(path):
    name = os.path.basename(path)
    return name[:-8] if name.endswith(".geojson") else os.path.splitext(name)[0]


def excluded(path):
    s = stem(path)
    return s == "cloudshell-ip-2" or s.startswith("check-")


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def find_coordinates(obj):
    """GeoJSON から [経度, 緯度] の 2 つの数を探す。見つからなければ None。"""
    if not isinstance(obj, dict):
        return None
    t = obj.get("type")
    geom = None
    if t == "Point":
        geom = obj
    elif t == "Feature":
        geom = obj.get("geometry")
    elif t == "FeatureCollection":
        feats = obj.get("features") or []
        if feats and isinstance(feats[0], dict):
            geom = feats[0].get("geometry")
    elif "coordinates" in obj:
        geom = obj
    if not isinstance(geom, dict):
        return None
    coords = geom.get("coordinates")
    if isinstance(coords, list) and len(coords) >= 2 and is_number(coords[0]) and is_number(coords[1]):
        return float(coords[0]), float(coords[1])
    return None


def find_properties(obj):
    """精度と信頼度を探す場所。properties があればそれ、無ければ最上位。"""
    if isinstance(obj, dict) and obj.get("type") == "FeatureCollection":
        feats = obj.get("features") or []
        if feats and isinstance(feats[0], dict):
            obj = feats[0]
    if isinstance(obj, dict) and isinstance(obj.get("properties"), dict):
        return obj["properties"]
    return obj if isinstance(obj, dict) else {}


def pick(props, words, prefer=None):
    """名前に words のどれかを含む数値の項目を、words の順に探す。prefer を含む名前を優先する。"""
    numeric = [(k, v) for k, v in props.items() if is_number(v)]
    for word in words:
        hits = [(k, v) for k, v in numeric if word in k.lower()]
        if prefer:
            preferred = [(k, v) for k, v in hits if prefer in k.lower()]
            if preferred:
                return preferred[0]
        if hits:
            return hits[0]
    return None


def haversine_m(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def bearing_name(lat1, lon1, lat2, lon2):
    """実際の位置（1）から推定位置（2）への初期方位角を、8 方位に丸める。"""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    deg = (math.degrees(math.atan2(x, y)) + 360.0) % 360.0
    return DIRECTIONS[int((deg + 22.5) // 45) % 8]


def fmt_num(v):
    if float(v).is_integer():
        return str(int(v))
    return f"{v:.2f}".rstrip("0").rstrip(".")


def fmt_distance(m):
    return f"{m:,.0f} m"


def width(text):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)


def pad(text, w):
    return text + " " * (w - width(text))


def print_table(header, rows):
    widths = [max(width(r[i]) for r in [header] + rows) for i in range(len(header))]
    print("  ".join(pad(h, w) for h, w in zip(header, widths)).rstrip())
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(pad(c, w) for c, w in zip(r, widths)).rstrip())


def ask_actual_position():
    """実際の位置を、入力した文字を表示しない形で尋ねる。"""
    print("手順 3-1 でメモした実際の位置を入力してください。入力した文字は画面に表示されません。")
    while True:
        try:
            lat = float(getpass.getpass("  緯度 -90〜90 の数   : ").strip())
            lon = float(getpass.getpass("  経度 -180〜180 の数 : ").strip())
        except ValueError:
            print("  ⚠️  数値として読めませんでした。もう一度入力してください。")
            continue
        except (EOFError, KeyboardInterrupt):
            print("")
            sys.exit(1)
        if -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0:
            print("  実際の位置を受け取りました。座標は表示しません。")
            print("")
            return lat, lon
        print("  ⚠️  緯度は -90〜90、経度は -180〜180 の範囲で入力してください。")


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def main(argv):
    if not argv:
        print('使い方: python3 "${HANDSON_DIR}/score.py" <応答の GeoJSON> [<応答の GeoJSON> ...]', file=sys.stderr)
        return 2

    skipped = [p for p in argv if excluded(p)]
    paths = [p for p in argv if not excluded(p)]
    if len(argv) >= 4:
        paths.sort(key=lambda p: (ORDER_OF.get(stem(p), len(ORDER_OF)), os.path.basename(p)))
    if not paths:
        print("表に含めるファイルがありません。", file=sys.stderr)
        return 2

    actual = None
    if any(stem(p) not in NOT_YOUR_LOCATION for p in paths):
        actual = ask_actual_position()

    header = ["手順", "ファイル名", "精度の値", "信頼度の値", "ずれ", "方角", "ずれと精度の比", "円の中か外か"]
    rows, notes, sentences = [], [], []
    acc_names, conf_names = {}, {}

    for path in paths:
        s = stem(path)
        name = os.path.basename(path)
        step = STEP_OF.get(s, DASH)
        data = load(path)
        if data is None:
            rows.append([step, name, DASH, DASH, DASH, DASH, DASH, DASH])
            notes.append(f"{name}: 応答のファイルが無いか、JSON ではありません")
            continue

        props = find_properties(data)
        acc = pick(props, ["horizontalaccuracy", "accuracy"])
        conf = pick(props, ["confidence"], prefer="horizontal")
        if acc:
            acc_names[name] = acc[0]
        if conf:
            conf_names[name] = conf[0]
        acc_text = fmt_num(acc[1]) if acc else "見つかりません"
        conf_text = fmt_num(conf[1]) if conf else "見つかりません"
        if not acc or not conf:
            keys = ", ".join(sorted(props.keys())) if props else "なし"
            notes.append(f"{name}: 見つからない項目があります。読んだ項目の名前: {keys}")

        if s in NOT_YOUR_LOCATION or actual is None:
            rows.append([step, name, acc_text, conf_text, DASH, DASH, DASH, DASH])
            continue

        coords = find_coordinates(data)
        if coords is None:
            rows.append([step, name, acc_text, conf_text, DASH, DASH, DASH, DASH])
            notes.append(f"{name}: 座標が見つかりません。python3 -m json.tool で中身を確かめてください")
            continue
        lon, lat = coords
        if abs(lat) > 90.0 >= abs(lon):
            lat, lon = lon, lat
            notes.append(f"{name}: 緯度とみなした値が 90 を超えていたため、座標の順序を入れ替えて読みました")

        dist = haversine_m(actual[0], actual[1], lat, lon)
        direction = DASH if dist < 1.0 else bearing_name(actual[0], actual[1], lat, lon)
        if acc and acc[1] > 0:
            ratio = dist / acc[1]
            ratio_text = f"{ratio:.1f}"
            inside = "中" if ratio < 1.0 else "外"
        else:
            ratio_text, inside = DASH, DASH
        rows.append([step, name, acc_text, conf_text, fmt_distance(dist), direction, ratio_text, inside])
        if direction == DASH:
            sentences.append(f"{step} {name}: 推定位置は、実際の位置から 1 m 未満です")
        else:
            sentences.append(f"{step} {name}: 推定位置は、実際の位置から{direction}に {fmt_distance(dist)}")

    print_table(header, rows)
    print("")
    for line in sentences:
        print(line)
    if sentences:
        print("")

    def names_line(label, mapping):
        """項目の名前を表示する。名前がファイルによって異なる場合は、多い方を先に書き、残りをファイルごとに書く。"""
        if not mapping:
            return f"{label}: 見つかりません"
        counts = {}
        for v in mapping.values():
            counts[v] = counts.get(v, 0) + 1
        main_name = max(counts, key=lambda v: counts[v])
        others = [f"{k} は {v}" for k, v in mapping.items() if v != main_name]
        if not others:
            return f"{label}: {main_name}"
        return f"{label}: {main_name}。ただし、" + "、".join(others)

    print(names_line("精度の項目", acc_names))
    print(names_line("信頼度の項目", conf_names))
    print("ずれと精度の比は、ずれ ÷ 精度の値です。1 より小さければ、実際の位置は円の中にあります。")
    print("円の中か外かは、精度の値をメートル単位の不確かさの半径とみなして判定しています。")
    if any(stem(p) in NOT_YOUR_LOCATION for p in paths):
        print("2-2 と 6-3 の行は、あなたの居場所の推定ではないため、ずれと方角を表示しません。")
    print("座標は表示していません。方角と距離だけでは、実際の位置も推定位置も分かりません。")
    for line in notes:
        print(f"⚠️  {line}")
    if skipped:
        print("表に含めないファイル: " + "、".join(os.path.basename(p) for p in skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
