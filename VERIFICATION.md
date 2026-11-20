# 検証結果

## 2026年11月21日 Pixel本番を0.4.0へ・客層ボタン

- Pixel 7a本番アプリを0.3.0（6）→0.4.0（7）へ上書き更新。更新前のDBと同期設定を`artifacts/pixel-v4-update/`へ退避。DB v2→v3移行後も商品・会計・明細が全項目一致、同期先は本番のまま。商品「tofi」が本番クラウドに登録され、田楽豆腐の写真（hash `a4858ea4…`）を紐付け（version 2）。Pixelは60秒以内に写真を取得し、単品画面に写真を表示（ダークモード）。
- 客層ボタンを1行に詰めた（AndroidはFilterChipから余白の小さいトグルへ、iOSは1行・縮小許可・高さ44pt）。狭いエミュレータで「子ども」「シニア」が折り返さないことを確認。
- リポジトリを初コミットし、非公開の`gapul/tofu-pos-v3`へpush。コミット前にgitleaksと各トークン文字列の照合で秘密情報が含まれないことを確認。

## 2026年11月21日 単品レジ画面・商品写真

- 単品画面（販売中の商品が1つで自動切り替え、客層任意、受け取った額は本数変更で「ちょうど」自動、確認ダイアログなし、6秒の取消通知）をエミュレータで確認: 2本・1,000円でお釣り200円（100円玉×2）、取消で理由「確定直後の取消」・`cancelled_here=1`・revision 2、通知表示中の次の会計も保存。通知がボタンに重なる問題を修正（Snackbarを88dp上げる）。
- 商品写真: Worker（`pnpm test` 30件）を本番へ（export → migration 0005 → deploy、version `6ce4a3a4-eea7-4b50-a94a-716cefba7301`）。田楽豆腐の写真（Slack「#99_豆腐大豆き」2026-11-18の商品画像、正方形800px・172KB）を本番に登録済み（hash `a4858ea4…`、商品への紐付けは本番の商品作成後）。
- エミュレータ: Photo Pickerで写真を選ぶ→800×534・83,757バイト・EXIFなしのJPEGで送信→商品にimage_hash・version 2。データ消去後の再同期で商品と写真を取得し、単品カードに写真表示。Android単体21件・lint成功、iOSはMacBookでビルド成功・`swift test` 30件。
- iPhoneへビルド11を無線インストール。本番は会計1件のまま。
- 注意: 通常版（debug）は本番設定を同梱するため、エミュレータで消去後に起動すると本番へつながる（今回は空だったため本番は不変、アプリは削除）。AGENTS.mdに試験は`synctest`のみと追記。

## 2026年11月21日 UI改訂・同梱接続・iPhone無線インストール

- 配色はSlack「#99_豆腐大豆き」をMatrix経由で読み、今年の立て看板ポスター・メニュー・フォトフレームの実色から抽出（記事の「ブランドカラー」画像はチャンネル未投稿で数値指定は取得できず）。同期タブ廃止・右上の同期状態アイコンと同期シート・詳細設定へ移動・履歴右上のCSVアイコン・豆腐マークの読み込み表示・ビルド同梱の接続設定（`src/<buildType>/assets/sync-default.json`、`ios/Config/sync-default.json`、gitignore済み）。
- Android: `testDebugUnitTest assembleDebug assembleSynctest lintDebug`成功。エミュレータで新規インストールの検証用アプリが設定なしで25秒後に自動同期し、他端末の会計69件を取り込み、右上アイコンが「同期済み」。サーバー側の失敗時は「同期に問題があります」に変わることも確認（検証用D1へ0004を当て忘れて503になった際）。
- Worker改訂2（在庫常時管理・`stop_at_zero`）を本番へ: 事前export → migration 0004 → deploy（version `969a4280-fbf9-4f46-8127-40887879ed41`）。`pnpm test` 28件。
- iOS 0.4.0: MacBookのXcodeで初回ビルドからエラーなし、`swift test` 28件成功。Mac miniで署名し、同じLANのiPhone（192.168.116.85）へ`ssh localhost`経由で無線インストール（T3直下のPythonはローカルネットワーク権限が無く不可）。ビルド9でDB v2→v3移行後の商品2件・会計3件・明細6行の一致を確認。
- 事故と復旧: 同梱接続入りのビルド10をiPhoneへ入れた直後、アプリが起動され、iPhoneに残っていたテスト用データ（会計3件・各3,641円、商品2件）が本番へ自動送信された。ユーザー確認で「テストなので送らない」と決定。iPhoneのDBを`artifacts/ios-device/iphone-test-data-20261121/`へ退避→アプリを削除→本番を`d1 export`で退避→該当の会計3件・明細6行・商品2件だけを本番D1から削除し、本番は会計1件（500円）・明細1行に戻ったことをダッシュボードで確認→空の状態でビルド10を再インストール。
- 教訓: 同梱接続は、未設定の既存端末へ上書き更新すると端末内の未送信データを本番へ送る。テストデータの残る端末へ入れる前にデータを消す。
## 2026年11月21日 TOS 0.4.0（複数端末・在庫・客層・レジ締め・ダッシュボード）

- 仕様: `docs/v4-spec.md`（末尾の改訂がレビュー反映）。Worker・Android・iOSを並行実装し、別コンテキストのレビューで出た指摘（①〜③の400で注文同期が止まる、棚卸と未送信販売の順序、理論値の端末判定、競合時の取り込み停止、文字数の数え方、修復SQL）を修正。
- Worker: `pnpm test` 26件成功、`deploy --dry-run`成功。新しいworkerdで起動できない名前付きexportを`src/lib.js`へ分離。
- 本番配備（2026-11-21 03:1x JST）: 事前に`d1 export`で本番を退避（`artifacts/prod-backup/`、会計1件・商品版1件）→ migration 0003 → Worker 0.4.0（version `c2df620f-0e8a-4189-b287-a9781b5cac90`）→ `repair/0003_after_deploy.sql` → `DASHBOARD_TOKEN_SHA256`登録。本番の会計1件にseq 1・created_at・明細1行が付き、0.3.0形式の再送はaccepted・`received_at`不変。`/dashboard`表示と、閲覧用トークンでの集計（500円・1件）を確認。閲覧用トークンは`artifacts/prod-backup/dashboard-token`（600）。
- 検証用ローカルWorkerで0.3.0時代の59件にmigrationを当て、seq 1..59・明細60行・取消4件を確認。ダッシュボードの集計値（純売上17,700円・55件・取消4件1,500円）をD1と照合し、390px幅の表示をヘッドレスブラウザで確認。
- Android（`testDebugUnitTest assembleDebug assembleSynctest lintDebug`成功、単体11件）をエミュレータ上の2アプリ（別端末扱い）で確認: 設定直後に他端末の会計を自動取り込み、商品作成と棚卸がクラウドへ、客層必須・預り金ボタン・釣銭内訳（100円玉×2）・会計の自動送信と客層列、端末間の在庫減少と売り切れ（押しても追加されない）、他端末の入荷を操作なしで45秒後に反映、レジ開け・締めと差額（−100円）がダッシュボードへ、取消で在庫が戻る、サーバー停止中の会計が復旧後に操作なしで自動送信（65秒）、他端末の会計をこの端末で取り消した返金を理論値から差し引く（5,000+400−400）、競合した会計は保留して自動送信せず取り込みは継続。
- 実機E2E中に、金種入力欄で0を消して打つと「5」が「50」になる不具合を発見し両OSで修正（0は空表示）。
- iOS: `verify-swift-core.sh`成功、Core型チェック成功。App本体はXcode未導入のため未ビルド（MacBookでビルド予定）。
- 未実施: Pixel本番アプリの0.4.0更新（ADB再認証待ち）、iOSビルドと実機確認、iOS↔Android間の実機相互確認。Androidの401停止状態はメモリ保持（再起動後は待機明けに1回だけ再試行）。

## 2026年11月20日のアプリ名変更（TOS）

- 表示名を「TOS」に変更（Androidのランチャー名・画面上部、iOSのホーム画面名・レジ画面タイトル）。検証用アプリは「TOS 検証」。パッケージ名・bundle ID・DB・同期先は変更なし（上書き更新でデータを保持するため）。
- Android `assembleSynctest assembleDebug lintDebug`成功、マージ後のmanifestで`TOS`／`TOS 検証`を確認。iOSはMacBookオフラインのため未ビルド。

## 2026年11月20日の自動同期（オンライン前提へ変更・実機未確認）

- ユーザー指示で「基本的にオンライン想定」に変更。会計・取消の確定後、起動・前面復帰時、接続設定の保存後に自動送信。50件超は5秒後に続きを送信。通信・サーバー失敗は永続化済みの待機時間（15〜300秒＋jitter、Retry-After最大1時間）経過後に前面にある間だけ自動再送。401／403と内容競合は直後の自動再送をしない（待機中に会計があれば待機明けに送るため、未解決の競合・不正トークンは最短5分ごとに再確認される）。会計は従来どおり通信を待たない。手動の「今すぐ送信」も同じ単一実行ロックを共有。
- Android: `POSApplication`に自動送信の調停（単一の予約、実行中の要求は完了後に1回だけ実行）、`CloudSync.autoRetryAt`で再送可否を返す。iOS: `CloudSyncController.active`（scenePhase）、`requestAutoSync`、`upload()`が再送時刻を返す。ビルド番号は8。
- Android `assembleSynctest assembleDebug testDebugUnitTest lintDebug`成功。
- 未実施: iOSビルド（MacBookがオフライン）、Pixel実機での自動同期E2E（Pixelがオフライン）。検証用Worker・`tailscale serve`の`/v1`・Pixelの画面消灯30分設定と検証用アプリは、実機確認のため残置中。

## 2026年11月20日のPixel実機での同期E2E（検証用アプリ）

- 営業データのある本番アプリ`dev.gapul.tofupos.v3`には触れず、同じPixel 7aへ別パッケージ`dev.gapul.tofupos.v3.synctest`（表示名「Tofu POS 検証」、`assembleSynctest`）を並べて入れ、Tailscale経由のADB（`100.76.47.30:5555`）で画面操作した。本番アプリのDB・同期設定のSHA-256は試験前後で一致、更新日時も不変。
- 同期先は本番Cloudflareではなく、同じ`cloudflare/src/worker.js`とmigrationをMac miniの`wrangler dev --local`（D1はローカルSQLite、`SHOP_ID=tofu-synctest`、専用トークン）で動かし、`tailscale serve`の`https://macmini.tail079f44.ts.net/v1`でPixelへ公開。本番D1・本番トークンは不使用。
- 実機で確認できた項目（すべて成功）:
  - 接続設定の手入力・同期先の固定、未同期0件での送信（「すべて同期済み」）。
  - 会計4件（複数明細・預り金あり）の送信、端末とD1の全項目一致。送信ボタン3連打でもPOSTは1回。
  - 再送：端末側は送信なし。同一ペイロードのAPI再送は全件accepted・`received_at`不変（D1書き換えなし）。不正トークンは401。
  - 全額取消の送信（revision 2・元金額保持）、古いrevision 1の再送は競合で取消を巻き戻さない。
  - 53件未同期で50件→残り3件、待機中の再押下は「待機中です」、再送で残り0。端末57件とD1の全項目一致。
  - サーバー停止（HTTP 502）で未同期を保持し待機時間を保存。アプリ強制終了・再起動後も「待機中です。6秒後」を表示。復旧後に送信成功し失敗回数0へ。
  - 商品バックアップ：IDが内容ハッシュ、同内容の再バックアップは行増加なし、価格変更で新しい版。24版で一覧1ページ目20件＋「さらに表示」で残り4件、最古の版を選択可能。
  - データ消去した検証用アプリへ最古の商品版と売上を復元：50件→続き8件→空ページで完了。横画面への回転と強制終了後も「売上の続きを復元」が残る。復元後58件がD1と全項目一致、synced_revision＝revision、過去単価450円を保持。クラウドで取消済みの未取込会計は取消状態で取込。
  - 再復元（売上のみ）：重複0件、取込済み会計へのクラウド側取消を反映（取消1件）、端末で取消済み・未送信の会計は巻き戻さない、内容が異なる同一ID会計は端末内容を保持（競合1件）。
  - サーバー停止中の復元失敗で商品・注文・明細・復元カーソル不変、待機時間を保存。
  - 送信時の内容競合：端末の取消は送信成功、競合会計は未同期のまま保持しD1不変、待機300秒。
- 未確認：誤トークンでの401表示は、端末がロック状態になったため実機操作できず（Worker単体テストとAPIで401は確認済み）。256KiB超の保留は、UI上の制約（商品名100文字・2商品）では作れないため単体テストのみ。端末のネット遮断はADB自体が切れるため、サーバー停止（502）で代替。
- `assembleDebug`の本番表示名は「Tofu POS」のまま（manifestPlaceholder）。`testDebugUnitTest assembleDebug lintDebug`成功、Workerテスト15件成功。
- 補足：ローカルの新しいworkerdは`worker.js`の関数以外の名前付きexport（`MAX_BYTES`等）を起動時に拒否したため、検証環境では`export default`だけを再exportする`entry.js`を使用。本番配備済みWorkerは動作中だが、今後のwrangler更新で配備時に同じエラーになる可能性がある。
- 証跡: `artifacts/sync-staging/`（`ui.py`、`shots/*.png`、`device*.sqlite`、`deviceA-final.sqlite`、`prod-before.sha`／`prod-after.sha`、`worker.log`、`android-checks.log`、`worker-tests.log`）。

## 2026年11月20日のiOSアプリアイコン（0.3.0 / ビルド7）

- iOSにアセットカタログがなく、ホーム画面のアイコンが未設定だった。`shared/branding/tofu-mark.svg`をAndroidと同じ緑`#006B57`背景・同比率で1024pxの不透明PNGに書き出し、`ios/Assets.xcassets/AppIcon.appiconset`と`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`を追加。ビルド番号を7へ。機能コードの変更なし。
- MacBookのXcode 27.2で実機向けビルド成功、`CFBundleIcons`にAppIconを確認。Mac miniで署名し`artifacts/TofuPOS-v3-0.3.0-7.ipa`を作成。
- iPhone 9 ProへUSB経由で`scripts/ios-device.py install`により上書き更新し、既存データの保持を確認。SpringBoardから取得したアイコン画像で緑背景の豆腐マークを確認。
- 証跡: `artifacts/icon-ios-build.log`、`artifacts/ios-device/20261120-111245/`（`springboard-icon.png`を含む）。

## 2026年11月20日のiPhone遠隔インストール環境

- iPhone 9 Pro（iPhone17,3 / iOS 27.2 / UDID 00008140-00154CE21468401C）をUSBで検出。旧0.1.1（2）から署名済み0.3.0（6）へアンインストールせず更新し、InstallCompleteとインストール情報を確認。
- 更新前DB v1を退避し、起動後のv2と商品2件・会計3件・全明細を全項目比較して一致。原単価・預り金・釣銭・取消も保持。新規会計や返金は作成していない。
- pymobiledevice3 11.61.0を固定した`python3 scripts/ios-device.py`を追加。固定UDID・IPA bundle ID照合、保存データ退避/検証付き更新、強制終了なしの起動、PID/PNG/DB保持smoke、プロセス限定の短時間ログ取得、無線初期設定を実装。複数操作をflockで拒否し、秘密を含むペアリング情報は表示しない。
- MacBook → TailscaleのSSH（別名macmini、接続先100.105.135.49）→ Mac mini → USB → iPhoneで、実際のinstallとsmokeを実行して成功。最終版の同期/復元状態を含むsmokeも同じ遠隔経路で成功。5秒のTofuPOS限定ログ取得が成功。履歴画面のPNGを確認。
- 新規ホスト用テスト5件成功。原会計だけでなく既存v2のrevision・synced_revision・sync_error・全sync_metadataも保持確認する。レビューで検出した同期/復元状態の比較不足を修正し、同期済み情報や復元カーソルの喪失を検出する回帰テストを追加。
- EnableWifiConnections=trueとRemotePairing初期設定をUSBで有効化。iPhone自体はTailscaleの100.107.156.128でオンラインだが、62078番への直通は接続拒否、BonjourのWi-Fi端末未検出。確認済みの遠隔方式にはUSB接続を維持する。USBを外す直通方式は未確認で、Wi-Fi接続の確認待ち。
- 手順は`docs/ios-device.md`。自動タップ/XCTest runner配布までは設定しておらず、今回確認したテストは起動・画面取得・データ保持・ログ取得。実機でテスト用注文を作る操作は含めない。
- 証跡: `artifacts/ios-remote-debug/install.log`、`data-verification.json`、`tailscale-remote-install-smoke.log`、`tailscale-final-smoke.log`、`host-tests.log`、`log-capture-check.log`、`artifacts/ios-device/<JST日時>/`。

## 2026年11月20日のTailscale実機デバッグ

- Tailscale上の`100.76.47.30:5555`へADBで接続。端末シリアル`32131JEHN35561`、Pixel 7a、アプリ0.3.0 / 6を確認。USB接続なしでネイティブ画面を操作。
- 最初は別アプリが前面へ移ってUI文字を取得できなかったため、データ取得後にTofu POSを前面へ戻して操作。実機の「商品をバックアップ」で既存商品1件の保存成功を確認。
- 操作前後で商品・注文・明細・取消・同期済みrevisionの全内容一致を確認。新規会計・返金・復元の書込み・データ削除・instrumentationテストは実行していない。
- 証跡: `artifacts/tailscale-backup-debug.log`、`artifacts/tailscale-backup-debug.json`。上記0.3.0実装時に未確認だった実機バックアップ操作を、今回確認済み。

## 2026年11月20日の商品バックアップ・売上復元（0.3.0 / ビルド6）

- Cloudflareにmigration 0002（不変商品スナップショット）と認証付き商品バックアップ・一覧・復元APIを配備。既存の売上・取消と同期APIを維持。Worker version `413a03bf-6897-4594-b40a-3c2ce0814f1d`。
- Worker 15件、Swift XCTest 17件、Android単体3件、専用エミュレータのDB 10件、計45件成功。Android APK・Lint（エラー0、警告8）、Xcode 27.2の実機向けビルド、IPA署名検証が成功。
- 両OSで、重複取り込みなし、端末の取消の保護、クラウドの新しい取消の反映、原会計の内容競合の保持、商品変更後も過去単価保持、SQL故障時のページ全体とカーソルのロールバック、不正カーソルの拒否、最終空ページでの累計件数保持を確認。
- レビューで、21種類以上の商品履歴の後に古い同内容を再保存すると一覧から選べなくなる問題を検出。日時・IDのキーセットによる20件単位の「さらに表示」を両OSへ追加。24版を作成して古い状態の再保存を書込み0のまま受け付け、全版を列挙できるテストで修正を確認。
- Pixel 7aに通常の上書きインストールで0.3.0を反映し、売上DBと暗号化接続設定の更新前後のSHA-256一致、バージョン0.3.0 / 6を確認。端末ロック中のため、元の商品1件はMac経由でAPIへバックアップ。実機でテスト会計の作成・削除やinstrumentationは行っていない。
- 空の専用エミュレータにOSファイル選択から接続設定を読み込み、ネイティブの復元画面で既存の商品1件と500円の会計1件を取り込み。元端末との商品・注文・明細の全項目一致、同期済みrevision 1を確認。回転後の続行と完了カーソル、繰り返し復元による重複なしを確認。同内容の商品バックアップもネイティブから成功し、履歴の500円表示を確認。
- 検証端末のネット接続を無効にした初回一覧取得は失敗し、商品・注文・復元カーソルは未変更。待機状態が再起動後にも保持されることを確認。接続復旧後の手動操作で復元成功。UIハーネス側の描画待ち・スクロール位置による途中の確認失敗は、表示完了後のSQL照合と最終スクリーンショットで確認し直した。
- iOSもバックアップ・復元UIとCoreを実装、Xcode実機向けビルドと署名済みIPAを用意。iPhoneは未接続のため実機更新・実画面の操作確認は未実施。
- ローカルDBはversion 2のまま、既存テーブルへの列変更なし。追加した進行状態と累計件数は既存sync_metadataへ保存。復元はユーザー操作で1ページずつ取得し、自動再試行やポーリングなし。
- 証跡: `artifacts/backup-worker-tests.log`、`backup-android-build.log`、`backup-android-store-tests.log`、`backup-swift-tests.log`、`backup-ios-build.log`、`backup-cloud-migration.log`、`backup-cloud-deploy.log`、`backup-native-verification.json`、`backup-emulator-*.png`。
- 成果物: `artifacts/TofuPOS-Android-v0.3.0.apk`、`artifacts/TofuPOS-v3-0.3.0-6.ipa`。使い方・50件単位の続行・商品と売上の保存範囲はREADMEへ記載。

## 2026年11月20日のPixel同期確認

- 接続中Pixelの500円会計1件が未同期（revision 1 / synced_revision 0）。同期画面から手動送信し、残り0件、synced_revision 1を確認。
- 同一注文IDを使ったCloudflare D1の主キー検索で500円・revision 1・取消なしを確認。既存の実会計を送信したもので、新規テスト会計の作成や削除、アプリの再インストール、コード変更は行っていない。
- 現在の仕様は手動アップロードのみ。自動送信と他端末の売上の取り込みは未実装。

## 2026年11月20日の豆腐アイコン

- Android 0.2.2（ビルド5）。Google Driveの「Are you Tofu?_ver.2 / KV / areyoutofu2026.ai」から「Tofu」のoの図形を抽出。元の曲線・クリップを保持し、公開PNGの白・薄黄色を使用。
- 緑背景と前景を分けたadaptive icon、円形マスク、Android 13以降のmonochrome、通常のアイコンリソースを設定。元のポスター・写真はAPKに同梱しない。出典と共通SVGは`shared/branding`。
- Android単体3件・APKビルド・Lintに成功。アイコンXMLの解析と`git diff --check`成功。専用エミュレータへ上書きインストールし、ランチャー上の円形アイコンとバージョン0.2.2を確認。
- Pixel 7aの再接続後、通常の`adb -s 32131JEHN35561 install -r`で0.2.2（ビルド5）へ更新。売上DBと暗号化同期設定の更新前後のSHA-256一致を確認。APKは`artifacts/TofuPOS-Android-v0.2.2.apk`。iOSのアイコン設定は今回変更していない。
- ログ・画面: `artifacts/android-tofu-icon-build.log`、`artifacts/branding/launcher.png`。

## 2026年11月20日のAndroid Material 3 Expressive化

- Android 0.2.1（ビルド4）。Jetpack Composeの`MaterialExpressiveTheme`、押下時の形状変化付き`ButtonShapes`、`LoadingIndicator`を導入。レジ・商品・履歴・同期の4画面、ダーク表示に対応。
- 既存AGP 8.10.1との互換性のためMaterial 3は`1.5.0-alpha18`を固定。安定版1.5.0はSDK 37・AGP 9.1が必要なため、今回はビルド環境全体の更新を行わない。
- `testDebugUnitTest assembleDebug lintDebug`成功。単体3件と、シリアルを明示した専用API 35エミュレータのDBテスト5件が成功。Lintはエラー0・警告7（依存更新候補、target SDK等）。Compose導入で旧JUnit 3ランナーの全依存スキャンが失敗したため、既存StoreTestクラスを明示して5件の成功を確認。
- ネットワークを無効にした専用エミュレータで、商品追加→会計→DBの会計1件・500円→全額取消→revision 2と理由保持を確認。同期画面の未同期1件表示も確認。最初の実操作で検出した商品・カート間のLazyColumnキー重複を修正済み。
- 横画面の再生成後にカート・預り金を保持し、会計確認が可能。実際の数値キーボードの完了キーでIMEとフォーカスが解除されることを確認。文字倍率1.5・ダーク表示でも会計確認が可能で、回転による会計の重複作成なし。
- 別コンテキストの読み取り専用レビューで年表示・短い画面の操作領域を修正し、再レビューで追加の重大な不具合なし。同期状態はApplicationに保持してActivity再生成に対応。
- 接続中Pixel 7aへ通常の`adb -s 32131JEHN35561 install -r`で更新。バージョン0.2.1とMainActivityの前面表示を確認。更新前後の売上DBと暗号化同期設定のSHA-256が一致。実機で会計データの作成・削除・instrumentationテストは行っていない。
- ログ・画面: `artifacts/android-expressive-build.log`、`artifacts/android-expressive-store-tests.log`、`artifacts/expressive-ui-test.log`、`artifacts/expressive-responsive-test.log`、`artifacts/expressive-finish-ui-test.log`、`artifacts/expressive-*.png`。画面テストの中間失敗は、横画面の固定座標と物理Enterによるハーネス側の問題で、スクロール領域に応じた座標と実際のIME完了キーで上記成功を確認。

## 2026年11月20日のCloudflare売上同期

- Workers `tofu-pos-v3-sync` と専用D1 `tofu-pos-v3` を配備。エンドポイントは `https://tofu-pos-v3-sync.gapul.workers.dev/v1/sync`。
- Workerテスト9件、Swift XCTest 12件、Android単体3件、専用API 35エミュレータのDBテスト5件が成功（合計29件）。Android APK・Lint、Xcode実機向けビルド、IPA署名検証も成功。
- 実Cloudflareに対し、初回受領・同一再送・取消受領・取消再送・古い会計の拒否・不正トークン401を確認。検証用の0円データは専用UUIDを指定して削除し、残数0を確認。
- Android専用エミュレータの画面操作で設定JSONの読込、オフライン送信失敗、永続cooldown、再起動後の待機保持、オンライン復旧後の同期、取消revision 2の受領を確認。D1からもrevision 2・取消済みを確認し、当該テストデータを削除。
- 同じ注文を100回再送してもD1の追加書込み0。最大50件の初回は対象IDの検索＋更新後確認の2読取、同一再送は1読取。認証・形式・サイズ不正はDBアクセス0。これらは本物のSQLite SQLでカウンター付き検証。
- v1→v2移行で既存会計・取消・過去単価を保持。旧revisionの応答で新しい取消を同期済みにしないこと、再起動後も待機状態を保持すること、不正ACKと異なる同期先の拒否を確認。
- レビューで判明したAndroidの全体タイムアウト、ローカルで有効なUnicode名・1000件超の明細の拒否、過大注文によるキュー詰まりを修正。追加テストで正常受付・サイズ超過保留・後続同期を確認。
- SwiftのMAX関数に文字列引数を渡すと旧ACKで同期版が戻る不具合を追加テストで検出。数値CASTへ修正し、旧ACK再到達後も同期版が戻らないことを確認。
- 接続中のPixel 7aには、ユーザーのAndroid接続の案内後、通常の`adb install -r`で0.2.0（ビルド3）をインストールし、アプリの接続設定ファイルを読み込み済み。Pixelで会計データは作成していない。
- iPhone用の署名付き0.2.0と接続設定JSONもTaildrop送信済み。現在iPhoneのUSB接続はなく、0.2.0のiPhone実機への更新・操作は未確認。
- ログ: `artifacts/cloud-worker-tests.log`、`artifacts/cloud-swift-tests.log`、`artifacts/cloud-emulator-only-tests.log`、`artifacts/cloud-final-android-build.log`、`artifacts/cloud-ios-build.log`。

### テスト対象の指定漏れ

最初の`connectedDebugAndroidTest`実行時、エミュレータだけを指定せず、接続中の実機Pixel 7aにもGradleのテストが実行された。テスト終了後、v3が端末からアンインストールされていることを確認。テスト前にその端末でv3の保存データがあったかは確認できない。テスト後にユーザーへ経緯を報告し、ユーザーがAndroidの接続を案内した後に上記の通常インストールを実施した。元の保存データが復元されたという確認はない。

再発防止として、ANDROID_SERIAL未指定・複数指定・許可なし実機指定でGradleタスクを停止するガードと、専用エミュレータを明示するAGENTS.md指示を追加。以降のテストログでは専用エミュレータ5件のみ実行されたことを確認している。実機への通常インストールと、アプリをインストール・削除するinstrumentationテストを区別する。

## 2026年11月20日の預り金フォーカス修正

- キーボードに「完了」を追加。スクロール、商品・数量変更、「ちょうど」、会計確認、レジ画面からの移動で預り金のフォーカスを解除する。
- Xcode 27.2で実機向けビルド成功、署名検証成功。
- iPhone 9 Proに0.1.1（ビルド2）をアンインストールなしで更新し、`InstallComplete (100%)`とアプリ一覧のバージョン0.1.1を確認。
- DB・会計ロジックの変更なし。キーボード操作の実機画面検証は未実施。

## 2026年11月20日の実機インストール

- Mac miniのUSBでiPhone 9 Proを識別し、署名済み`TofuPOS-v3-0.1.0-1.ipa`をインストール。
- インストーラーが`InstallComplete (100%)`で正常終了。
- 端末のアプリ一覧から`dev.gapul.tofupos.v3`、バージョン`0.1.0`、表示名`Tofu POS`を確認。
- インストール完了を確認済み。実機画面での起動・会計操作は未確認。

## 2026年11月19日の再検証

- 現在のソースをMacBook上の専用テストディレクトリへ転送し、Xcode 27.2でiPhone実機向けビルド成功。
- `swift test`: XCTest 7件、失敗0。会計金額境界、0円、預り不足、100回の同一会計要求、異なる内容のID再利用拒否、再読込、過去単価、全額取消・二重取消拒否、途中書込みのロールバック、未知スキーマ拒否、共通CSVを検証。
- Mac miniの`sh scripts/verify-swift-core.sh`も成功。
- Androidの`testDebugUnitTest`をキャッシュを使わず再実行し、2件、失敗0。金額境界と共通CSVを検証。
- Wi-Fi・モバイル通信を無効にした専用API 35エミュレータで`connectedDebugAndroidTest`を再実行し、2件、失敗0。SQLite永続化・価格保持・100回の再実行・取消・故障注入ロールバックを検証。
- Android APKビルド・Lint成功。Lintの既知警告とiOS画面向きの警告は残るが、ビルドエラーはなし。
- iPhone 9 ProはXcodeの接続端末に現れず、MacBookにはiOSシミュレータのランタイムも未導入。今回のiOS画面操作・実機インストールは未確認。
- 実装コードの変更はなし。ログは`artifacts/android-test-20261119.log`、`artifacts/android-runtime-test-20261119.log`、`artifacts/swift-tests-20261119.log`、`artifacts/ios-build-20261119.log`。

## 2026年11月18日の検証

2026年11月18日 JST。初版のローカル実装に対する結果。

## 成功

- Android: `./gradlew testDebugUnitTest assembleDebug lintDebug`。単体テスト2件、失敗0。Lintはエラー0（対象SDK・ツール更新・バックアップ設定・アイコン・ローカライズに関する警告あり）。
- Android API 35専用エミュレータ: `connectedDebugAndroidTest`、DBテスト2件、失敗0。ファイルDBの再読込、価格スナップショット、同一会計100回、取消、故障注入ロールバック。
- Android画面操作: 商品登録、数量2、500円×2、預り2000円・釣銭1000円、タブ移動後の釣銭表示、会計確定、アプリ強制終了・再起動後の会計保持、全額取消後の売上0円・取消1件を確認。
- Android CSV保存: OSの保存先選択からDownloadsへ保存し、ファイルを読み戻して取消行の元額1000円・純売上0円を確認。
- Swift: `sh scripts/verify-swift-core.sh` 成功。金額境界、不正入力拒否、ファイルDBの再読込、過去単価、100回再実行、異なる内容の会計ID再使用拒否、取消、故障注入ロールバック、0円会計、共通CSV一致。
- 両OSのCSV出力が `shared/golden-sales.csv` とバイト単位で一致。
- XcodeGenでiOSプロジェクト生成、生成pbxprojの`plutil -lint`成功、SwiftUIソースの構文解析成功。
- `git diff --check`成功。
- 別コンテキストの読み取り専用レビューを実施。AndroidのUIスレッド外入力参照と画面復帰時の釣銭表示を修正し、ビルドと画面操作で確認。

## iOSビルドと送付の追加確認

- MacBookのXcode 27.2（27B52）でiPhone実機向けのビルド成功。バージョンは0.1.0、ビルド番号1。
- 同じ環境で`swift test`成功。XCTest 7件、失敗0。
- Mac miniの開発証明書とiPhone 9 Proを含む開発用プロファイルで署名し、`codesign --verify --deep --strict`成功。
- `artifacts/TofuPOS-v3-0.1.0-1.ipa`をiPhone 9 ProへTaildrop送信済み。先行して送ったバージョン情報不足のファイルではなく、この名前の修正版を使用する。
- MacBookのTailscale Serve経由でHTTPSのインストール用manifestとIPAを配信し、ダウンロード後のSHA-256一致を確認。
- 配信先: `https://macbook-mini.tail079f44.ts.net/tofu-pos-v3/`。既存の8375番サービスは維持し、443番の専用パスに追加。HTTPバックエンドは127.0.0.1:8766、配信対象はキャッシュ内のdeliveryディレクトリのみ。
- iPhone側のインストール許可・完了と実機上の操作は未確認。MacBookが起動し、iPhoneのTailscaleが接続されている間にインストールリンクを使用する。

## 未確認と環境の制約

- Mac miniには完全なXcode本体／iOS SDKがありませんが、MacBook経由で画面ビルドとXCTestを検証済みです。iOSのシミュレータ・実機上の操作は未確認です。
- Mac miniの`swift test`はCommand Line ToolsにXCTestがないため実行できません。Mac miniでは代替検証、MacBookではXCTest 7件の成功を確認しました。
- Android実機、API 26、長時間連続運用、大量履歴での性能、iOSファイル保存画面は未確認。
- 初版の時点ではクラウド同期は対象外だったが、0.2.0で手動売上同期を追加。復元用バックアップは未対応で、CSV出力のみで完全な端末復元はできません。
