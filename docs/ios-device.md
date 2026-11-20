# iPhoneの遠隔インストール・デバッグ

対象はiPhone 9 Pro（UDID `00008140-00154CE21468401C`）とアプリ `dev.gapul.tofupos.v3`。別端末や全端末へ一括操作しない。

## 確認済みの接続経路

別のMac → TailscaleのSSH → Mac mini（`100.105.135.49`）→ USB → iPhone。

MacBookのSSH別名`macmini`が上記Tailscale IPを使用することを確認し、実際に遠隔インストールとsmokeを実行済み。この方式ではiPhoneをMac miniへUSB接続したまま使う。iPhoneのロックは解除しておく。

iPhone自体もTailscaleの`100.107.156.128`でオンライン。`EnableWifiConnections=true`とRemotePairingの初回設定は有効化済みだが、同IPの62078番は接続拒否で、Bonjourの無線端末も未検出。USBを外した直接接続はまだ確認できていない。USBホスト経由の遠隔操作と区別する。

## コマンド

Mac miniのリポジトリで実行する。`uvx`が必要で、補助ツールは`pymobiledevice3==11.61.0`に固定。Xcode本体・sudoは実行ホストに不要。署名済みIPAは別途Xcodeと既存プロファイルで用意する。

```sh
python3 scripts/ios-device.py status
python3 scripts/ios-device.py install artifacts/TofuPOS-v3-0.3.0-6.ipa
python3 scripts/ios-device.py smoke
python3 scripts/ios-device.py screenshot
python3 scripts/ios-device.py logs --seconds 15
```

MacBookから遠隔で実行する例:

```sh
ssh macmini 'cd /Users/gapul/Developer/github.com/gapul/tofu-pos-v3 && python3 scripts/ios-device.py status'
ssh macmini 'cd /Users/gapul/Developer/github.com/gapul/tofu-pos-v3 && python3 scripts/ios-device.py install artifacts/TofuPOS-v3-0.3.0-6.ipa'
ssh macmini 'cd /Users/gapul/Developer/github.com/gapul/tofu-pos-v3 && python3 scripts/ios-device.py smoke'
```

結果・ログ・更新前後のSQLiteは`artifacts/ios-device/<JST日時>/`へ保存。ディレクトリとファイルは自分だけが読める権限で作り、リポジトリにコミットしない。`--output DIR`で出力先を指定可能。同時操作はロックで拒否する。

## 保持とテストの範囲

- `install`はIPAのbundle IDと端末UDIDを照合し、アンインストールせず更新。既存DBを退避して、更新・起動後に商品・原会計・明細を照合する。同じDBバージョンではrevision・同期済みrevision・保留理由・同期メタデータも比較。既知のv1→v2移行は新規項目の初期値を別途確認する。
- インストールするとiOSがアプリを終了するため、会計入力中を避けて更新する。未確定カートは保存済み会計とは別で、保持確認の対象外。
- `smoke`はアプリを強制終了せず起動し、PID・PNG画面取得・DB保持を確認する。新規会計・返金・同期・復元のボタンは自動では押さない。
- `logs`はTofuPOSプロセスのログだけを1〜60秒間取得する。
- これは起動・保持のsmoke test。自動タップによるUI操作テストやXCTest runnerの配布は別途設定が必要。CoreのテストはXcodeのあるMacBookで既存の`swift test`を実行できる。

実機で確認した更新は0.1.1（2）→0.3.0（6）。商品2件・会計3件・全明細を保持し、DB v1→v2移行、起動、履歴画面を確認。

## 無線設定・直接接続

USBの信頼済み接続がある状態で、次を実行して初回設定を再確認できる。

```sh
python3 scripts/ios-device.py wireless
```

ペアリング情報はデバイス秘密を含むため表示せず、ツールの通常保存先とアクセス制限したログに保存する。他のMacにはコピーせず、SSHでUSBホストを使う。

将来、iPhoneのWi-Fi/Tailscale側62078番が到達可能になった場合は、`--host`で明示した接続先を使える。現在は未確認の経路なので常用コマンドにはしない。

```sh
python3 scripts/ios-device.py --host 100.107.156.128 status
```

CLIの根拠: [pymobiledevice3 lockdown / Wi-Fi・RemotePairing](https://doronz88.github.io/pymobiledevice3/latest/cli/lockdown/)、[接続API](https://doronz88.github.io/pymobiledevice3/latest/api/connection/)。

## ホスト側の検証

```sh
python3 -m unittest discover -s scripts -p 'test_ios_device.py' -v
```

同期済み情報・復元カーソル消失を成功扱いしないこと、業務データ差分の拒否、既知のlossless移行だけを許可することを検証する。

## 同じLANからの無線インストール（2026-11-21確認）

iPhoneがMac miniと同じLAN（Wi-Fi）にいれば、USBなしでインストールできる。iPhoneのLAN IPはBonjourで調べる（`dns-sd -B _apple-mobdev2._tcp` → `dns-sd -L <名前> _apple-mobdev2._tcp` → `arp -an`）。

- T3から直接起動したPythonは、macOSの「ローカルネットワーク」の権限がなくLANの端末へ`No route to host`になる（`nc`/`curl`は通る）。**`ssh localhost`経由で実行する**と通る。
- インストール: `ssh localhost 'cd <repo> && python3 scripts/ios-device.py --host <iPhoneのLAN IP> install <IPA>'`。インストールと更新前DBの退避までは通るが、起動・画面取得（developerサービス）は`--host`では動かない。
- 起動・画面取得・DB照合はトンネルを張って行う: `ssh localhost 'sudo -n uvx --from pymobiledevice3==11.61.0 pymobiledevice3 lockdown start-tunnel --mobdev2-host <IP> --script-mode'`（表示されたRSDアドレス・ポートを`--rsd`に渡す）→ `developer core-device launch-application --no-kill-existing dev.gapul.tofupos.v3 --rsd ...` → `apps pull dev.gapul.tofupos.v3 "Library/Application Support/tofu-pos.sqlite" after.sqlite --mobdev2-host <IP>`。終わったらトンネルを止める。
- 画面取得は前面のアプリを撮る。TOSが前面でないと利用者の別アプリの画面が写るので、撮る前にTOSが前面か確認する。
- Tailscale IP（100.107.156.128）経由は、Wi-Fi接続中でも62078番が拒否され使えない。
