<#
.SYNOPSIS
  AWS Deep Cuts - AWS IoT Core Device Location ハンズオン
  あなたの PC で周囲の Wi-Fi を測り、測定値を wifi.json に保存します。AWS は呼び出しません。

.DESCRIPTION
  使い方（PC の作業フォルダ $HOME\iotdl-handson で実行します）:
    powershell -ExecutionPolicy Bypass -File .\scan-wifi-windows.ps1 -IncludeIp

  -IncludeIp は任意です。付けると、手順 4-3 で使う PC の IP アドレスを ip.json に保存します。
  -Max で、残すアクセスポイントの数を変えられます。既定は 10 台です。
  -OutDir で、保存先のフォルダを変えられます。既定は現在のフォルダです。

  スクリプトが行うこと:
    0. Wi-Fi の再スキャンを依頼し、4 秒待つ。netsh wlan show networks は、Windows が最後に
       スキャンした結果を表示するだけで、自分ではスキャンしません。そのままでは接続中の
       アクセスポイントしか表示されないことがあるため、WLAN API の WlanScan を呼びます。
       管理者の権限は要りません。Microsoft のドキュメントでは、ドライバーは 4 秒以内に
       スキャンを終えることになっています。依頼できなかった場合も、そのまま netsh の結果を読みます。
    1. netsh wlan show networks mode=bssid の出力から、BSSID とシグナルを取り出す。
       BSSID は、アクセスポイントの MAC アドレスです。行の名前は表示の言語で変わるため、
       値の形で読み取ります（日本語の「シグナル」と英語の「Signal」の両方で動きます）。
    2. シグナルを受信信号強度（dBm）に換算する。シグナルは百分率で、dBm ではありません。
       Microsoft の WLAN API のドキュメントでは、信号の品質の 0 % は -100 dBm、100 % は -50 dBm で、
       その間は線形に補間します。netsh のシグナルがこの値と同じかは書かれていないため、
       dBm ≒ シグナル ÷ 2 − 100 は近似です。
    3. ローカル管理アドレスを除く。ローカル管理アドレスは、機器が自分で決めた MAC アドレスで、
       スマートフォンのテザリングなどで使われることが多いものです。送るアドレスを減らすために除きます。
    4. 受信信号強度の強い順に、最大 Max 台を残す。
    5. SSID（ネットワークの名前）は書き出さない。

  wifi.json は、近隣のアクセスポイントの MAC アドレスを含みます。公開しないでください。

  このファイルは、Windows PowerShell 5.1 が日本語を正しく読めるように、BOM 付きの UTF-8 で保存しています。
  作成する wifi.json と ip.json は、AWS CLI が読めるように BOM 無しの UTF-8 で書きます。
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 100)]
  [int]$Max = 10,
  [switch]$IncludeIp,
  [string]$OutDir = (Get-Location).Path
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$wifiPath = Join-Path $OutDir 'wifi.json'
$ipPath = Join-Path $OutDir 'ip.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
Write-Host '  AWS Deep Cuts - 周囲の Wi-Fi を測る（Windows）'
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
Write-Host ''
Write-Host '測定の方法: netsh wlan show networks mode=bssid（シグナルの百分率から dBm ≒ シグナル ÷ 2 − 100 で近似）'

# ─── 0. Wi-Fi の再スキャンを依頼する ─────────────────────────────
# netsh は最後のスキャンの結果を表示するだけなので、先に WlanScan で再スキャンを依頼する。
# WLAN_INTERFACE_INFO_LIST は、件数と index（各 4 バイト）の後に、
# WLAN_INTERFACE_INFO（GUID 16 バイト + WCHAR[256] 512 バイト + 状態 4 バイト = 532 バイト）が並ぶ。
try {
  if (-not ('DeepCutsWlanRescan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DeepCutsWlanRescan {
  [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiatedVersion, out IntPtr handle);
  [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
  [DllImport("wlanapi.dll")] static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
  [DllImport("wlanapi.dll")] static extern uint WlanScan(IntPtr handle, ref Guid iface, IntPtr ssid, IntPtr ie, IntPtr reserved);
  [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
  public static int Scan() {
    uint negotiated;
    IntPtr handle;
    if (WlanOpenHandle(2, IntPtr.Zero, out negotiated, out handle) != 0) return 0;
    int requested = 0;
    try {
      IntPtr list;
      if (WlanEnumInterfaces(handle, IntPtr.Zero, out list) != 0) return 0;
      try {
        int count = Marshal.ReadInt32(list);
        for (int i = 0; i < count; i++) {
          IntPtr item = new IntPtr(list.ToInt64() + 8 + i * 532);
          Guid iface = (Guid)Marshal.PtrToStructure(item, typeof(Guid));
          if (WlanScan(handle, ref iface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0) requested++;
        }
      } finally { WlanFreeMemory(list); }
    } finally { WlanCloseHandle(handle, IntPtr.Zero); }
    return requested;
  }
}
'@
  }
  if ([DeepCutsWlanRescan]::Scan() -gt 0) {
    Start-Sleep -Seconds 4
  }
} catch {
  # 再スキャンを依頼できなくても、netsh が表示する最後のスキャンの結果で続ける
}

# ─── 1. netsh の出力から BSSID とシグナルを取り出す ─────────────────
$raw =@(& netsh wlan show networks mode=bssid | ForEach-Object { [string]$_ })
$netshExit = $LASTEXITCODE

$found = New-Object System.Collections.Generic.List[object]
$currentMac = $null
foreach ($line in $raw) {
  if ($line -match '^\s*BSSID\s+\d+\s*:\s*([0-9A-Fa-f:]{17})') {
    $currentMac = $Matches[1]
    continue
  }
  # BSSID の行の後で、最初に現れる「: 数字%」の行がシグナル
  if ($null -ne $currentMac -and $line -match ':\s*(\d+)\s*%') {
    $found.Add([pscustomobject]@{ Mac = $currentMac; Signal = [int]$Matches[1] })
    $currentMac = $null
  }
}

if ($netshExit -ne 0 -or $found.Count -eq 0) {
  Write-Host ''
  Write-Host '❌ アクセスポイントが見つかりませんでした。wifi.json は作成していません。'
  Write-Host '   netsh の出力（SSID の行を除く）:'
  foreach ($line in $raw) {
    if ($line.Trim().Length -gt 0 -and $line -notmatch '^\s*SSID\s+\d+\s*:') {
      Write-Host ('     ' + $line.Trim())
    }
  }
  Write-Host '   Wi-Fi が有効か、README の手順 3-2 の位置情報の設定を確かめてください。'
  exit 1
}

# ─── 2〜4. 換算、ローカル管理アドレスの除外、並べ替え ─────────────────
$excluded = 0
$candidates = New-Object System.Collections.Generic.List[object]
foreach ($ap in $found) {
  $mac = $ap.Mac.ToUpperInvariant().Replace('-', ':')
  if ($mac -notmatch '\A([0-9A-F]{2}:){5}[0-9A-F]{2}\z') { continue }
  # 最初のオクテットの下から 2 ビット目が 1 のアドレスは、ローカル管理アドレス
  if (([Convert]::ToInt32($mac.Substring(0, 2), 16) -band 2) -ne 0) {
    $excluded++
    continue
  }
  $rss = [int][math]::Round($ap.Signal / 2 - 100)
  if ($rss -gt 0) { $rss = 0 }
  if ($rss -lt -128) { $rss = -128 }
  $candidates.Add([pscustomobject]@{ Mac = $mac; Rss = $rss })
}

$seen = @{}
$aps = New-Object System.Collections.Generic.List[object]
foreach ($ap in ($candidates | Sort-Object -Property Rss -Descending)) {
  if ($seen.ContainsKey($ap.Mac)) { continue }
  $seen[$ap.Mac] = $true
  $aps.Add($ap)
  if ($aps.Count -ge $Max) { break }
}

if ($aps.Count -eq 0) {
  Write-Host ''
  Write-Host '❌ 送れるアクセスポイントがありませんでした。wifi.json は作成していません。'
  Write-Host ('   除いたローカル管理アドレス: {0} 台' -f $excluded)
  Write-Host '   Wi-Fi が有効か、README の手順 3-2 の位置情報の設定を確かめてください。'
  exit 1
}

# ─── 5. wifi.json を書き出す（1 行に 1 つのキー。SSID は書き出さない。BOM 無し）──
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('[')
for ($i = 0; $i -lt $aps.Count; $i++) {
  $lines.Add('  {')
  $lines.Add(('    "MacAddress": "{0}",' -f $aps[$i].Mac))
  $lines.Add(('    "Rss": {0}' -f $aps[$i].Rss))
  if ($i -lt $aps.Count - 1) { $lines.Add('  },') } else { $lines.Add('  }') }
}
$lines.Add(']')
[System.IO.File]::WriteAllText($wifiPath, (($lines -join "`n") + "`n"), $utf8NoBom)

Write-Host ''
Write-Host ('wifi.json に保存したアクセスポイント: {0} 台（MAC アドレスの前半 4 オクテットを伏せて表示）' -f $aps.Count)
foreach ($ap in $aps) {
  Write-Host ('  **:**:**:**:{0}  {1} dBm' -f $ap.Mac.Substring(12), $ap.Rss)
}
if ($excluded -gt 0) {
  Write-Host ('除いたローカル管理アドレス: {0} 台' -f $excluded)
}
Write-Host ('保存先: {0}' -f $wifiPath)

# ─── 任意: PC の IP アドレスを ip.json に保存する ──────────────────
if ($IncludeIp) {
  Write-Host ''
  $ip = ''
  try {
    # 古い既定の設定でも接続できるように、TLS 1.2 を有効にする
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # 応答の末尾には改行が付くため、Trim() で取り除く
    $ip = ([string](Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -UseBasicParsing)).Trim()
  } catch {
    $ip = ''
  }
  # .NET の $ は末尾の改行の前でも一致するため、\A と \z で文字列の先頭と末尾を指定する
  if ($ip -match '\A\d{1,3}(\.\d{1,3}){3}\z') {
    [System.IO.File]::WriteAllText($ipPath, ('{{"IpAddress": "{0}"}}' -f $ip) + "`n", $utf8NoBom)
    Write-Host ('PC の IP アドレスを保存しました: {0}' -f $ipPath)
  } else {
    Write-Host '⚠️  IP アドレスを取得できませんでした。手順 4-3 は行わずに進めてください。'
  }
}

Write-Host ''
Write-Host '⚠️  wifi.json は、近隣のアクセスポイントの MAC アドレスを含みます。公開しないでください。'
