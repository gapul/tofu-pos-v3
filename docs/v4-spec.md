# TOS 0.4.0 仕様（オンライン前提・複数端末）

ユーザー決定（2026-11-21）: できるだけ早く全部。商品マスタと在庫はクラウドが正。客層は年代×性別の固定2軸。ダッシュボードはWebページ。

対象機能: 他端末の売上の自動取り込み / 商品マスタの自動同期 / ダッシュボード / 在庫管理 / 客層 / 預り金のボタン入力 / お釣り管理（釣銭の内訳表示と現金在高） / レジ開け・レジ締め。

既存の不変条件は維持する: 金額は整数円、数量1〜999、会計合計0〜1,000,000,000円、取消は全額のみで元注文を残す、会計IDの冪等性、注文と明細の同一トランザクション、過去単価の保持、会計は通信を待たない、通信は単一実行・永続化した待機時間（既存のsyncGate）を守る、401/403と内容競合は自動再送しない。

## バージョン

- アプリ 0.4.0。Android `versionCode = 7`、iOS `CURRENT_PROJECT_VERSION = 9`。
- 端末DB version 3（v2→v3はデータを消さない移行。v1→v3も通る）。
- D1 migration `0003_v4.sql`。既存の`cloud_orders`/`cloud_catalogs`の行は消さない。
- APIの`schema_version`は全て1のまま（追加フィールドのみ）。0.3.0の端末からの送信も受け付け続ける。

## 共通の値

- 年代 `customer_age`: `child`（子ども）/ `student`（学生）/ `adult`（大人）/ `senior`（シニア）
- 性別 `customer_gender`: `male`（男性）/ `female`（女性）/ `other`（その他・回答なし）
- 金種キー（文字列）: `"10000","5000","2000","1000","500","100","50","10","5","1"`。枚数は整数0〜9999。
- 端末ID `device_id`: 初回起動時に生成するUUID文字列（`sync_metadata`の`device_id`）。端末名 `device_label`: Androidは`Build.MODEL`、iOSは`UIDevice.current.name`（最大64文字）。

## 注文ペイロード（/v1/sync, /v1/restore, /v1/feed で共通）

既存フィールドに任意フィールドを追加: `device_id`（1〜64文字）, `customer_age`, `customer_gender`。

- Workerの`normalize`は、これらがnull/未指定なら**出力に含めない**（0.3.0の既存行とpayload/hashが一致し続けるため）。指定されていれば上記の値のみ許可（不正なら400）。
- base_hash（取消前の内容）にもこれらを含める（同じrevisionで内容が違えば競合）。
- 端末は新規会計で3つとも必ず付ける（年代・性別は会計時に必須選択）。0.3.0時代の会計はnullのまま。

## D1 migration 0003

```sql
ALTER TABLE cloud_orders ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE cloud_orders ADD COLUMN device_id TEXT;
ALTER TABLE cloud_orders ADD COLUMN customer_age TEXT;
ALTER TABLE cloud_orders ADD COLUMN customer_gender TEXT;
ALTER TABLE cloud_orders ADD COLUMN created_at TEXT;
-- 既存行: seqを主キー順で1..Nに振り、created_atをpayloadから埋める（JSON1）。
CREATE INDEX cloud_orders_seq ON cloud_orders(shop_id, seq);
CREATE TABLE cloud_order_lines(shop_id TEXT NOT NULL, order_id TEXT NOT NULL, product_id TEXT NOT NULL,
  quantity INTEGER NOT NULL, price INTEGER NOT NULL, cancelled INTEGER NOT NULL, PRIMARY KEY(shop_id, order_id, product_id));
CREATE INDEX cloud_order_lines_product ON cloud_order_lines(shop_id, product_id, cancelled);
CREATE TABLE cloud_products(shop_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, price INTEGER NOT NULL,
  active INTEGER NOT NULL DEFAULT 1, track_stock INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL,
  seq INTEGER NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(shop_id, id));
CREATE INDEX cloud_products_seq ON cloud_products(shop_id, seq);
CREATE TABLE cloud_stock_events(shop_id TEXT NOT NULL, id TEXT NOT NULL, product_id TEXT NOT NULL, delta INTEGER NOT NULL,
  kind TEXT NOT NULL, reason TEXT, created_at TEXT NOT NULL, received_at TEXT NOT NULL, PRIMARY KEY(shop_id, id));
CREATE INDEX cloud_stock_events_product ON cloud_stock_events(shop_id, product_id);
CREATE TABLE cloud_sessions(shop_id TEXT NOT NULL, id TEXT NOT NULL, device_id TEXT NOT NULL, device_label TEXT NOT NULL,
  opened_at TEXT NOT NULL, closed_at TEXT, payload TEXT NOT NULL, received_at TEXT NOT NULL, PRIMARY KEY(shop_id, id));
```

既存`cloud_orders`の明細も`cloud_order_lines`へ移行時に展開する（JSON1の`json_each`）。

### seq（変更フィード用の店舗内通し番号）

注文・商品の作成/更新のたびに、その店舗の `MAX(cloud_orders.seq, cloud_products.seq) + 1` を同じD1 batch（トランザクション）内のサブクエリで振る。在庫が変わった商品（販売・取消・在庫調整）もseqを進め、フィードで最新在庫が届くようにする。

### 在庫（クラウドが正、派生値）

`track_stock=1`の商品の在庫 = `SUM(cloud_stock_events.delta)` − `SUM(cloud_order_lines.quantity WHERE cancelled=0)`。`track_stock=0`は在庫管理なし（null扱い）。負数もあり得る（同時販売）。

- 注文の書き込みが勝ったとき（既存のpayload_hash検証と同じbatch）、その注文の明細を`cloud_order_lines`へ`INSERT OR REPLACE`し、取消（revision 2）なら`cancelled=1`に更新する。どちらも`EXISTS(SELECT 1 FROM cloud_orders WHERE shop_id=? AND id=? AND payload_hash=?)`で守り、同一要求の並行再送でも二重計上しない（REPLACEは冪等）。
- 在庫の見かけの値は読み出し時に集計する（インデックス付きの集計）。

## 端末→クラウドのAPI（全て既存と同じBearer端末トークン、Cache-Control: no-store）

### POST /v1/sync（既存、拡張）

注文の任意フィールド対応、seq・新列・明細表の更新。応答は従来どおり`{schema_version:1, accepted, conflicts}`。

### POST /v1/products

`{schema_version:1, products:[{id, name, price, active:bool, track_stock:bool, base_version:int}]}`（最大100件・256KiB）

- 行が無い: `base_version`は0のみ受理 → version 1で作成。
- 行が有り`base_version == version`: 反映しversion+1（内容が同じなら書き込まず`applied`）。
- 行が有り内容が要求と完全一致: 書き込まず`applied`（応答喪失後の再送）。
- それ以外: `conflict`（サーバー側を変えない）。
- 応答: `{schema_version:1, results:[{id, status:"applied"|"conflict", product:<現在の商品>}]}`。商品表現は下記フィードと同じ。
- 名前1〜100文字（前後空白除去後）、価格0〜1,000,000,000。

### POST /v1/stock

`{schema_version:1, events:[{id(UUID), product_id, kind:"add"|"set", quantity:int, reason?:string(≤200), created_at}]}`（最大100件）

- `add`: delta=quantity（-1,000,000〜1,000,000）。`set`（棚卸）: delta = quantity − 処理時点の在庫（quantityは0〜1,000,000）。
- `id`で冪等（`INSERT OR IGNORE`、同じidの再送は書き込まない）。対象商品が無い/`track_stock=0`ならその件は`rejected`。
- 応答: `{schema_version:1, accepted:[id...], rejected:[{id, reason}], products:[<影響した商品の現在値>]}`。

### POST /v1/sessions（レジ開け・締め）

`{schema_version:1, sessions:[{id, device_id, device_label, opened_at, closed_at|null, float:{金種:枚数}, float_total, counted:{..}|null, counted_total|null, expected_total|null, sales_total, cancel_total, order_count}]}`（最大20件）

- idでupsert。締め済み（closed_atあり）の行は以後変更しない（同内容の再送は成功扱い）。
- 合計値は金種×枚数と一致することを検証。
- 応答: `{schema_version:1, accepted:[id...]}`。

### GET /v1/feed?after=<seq>（他端末の売上・商品・在庫の取り込み）

- `after`は0以上の整数（未指定0）。`seq > after`の注文（最大100件）と商品（最大1000件）を取り、seq昇順でマージし、UTF-8で合計512KiBまでで切る（最初の1件は必ず含める）。
- 応答: `{schema_version:1, after, next, has_more, products:[...], orders:[...]}`。`next`は含めた最後のseq（何も無ければ`after`）。
- 商品: `{id, name, price, active, track_stock, version, stock(track_stock=0ならnull), seq}`。
- 注文: 注文ペイロード＋`seq`。
- 書き込みなし。

### 既存の /v1/catalogs, /v1/restore はそのまま残す。

## ダッシュボード

- `GET /dashboard`: 静的HTML（データを含まない）。トークン入力欄があり、`sessionStorage`に保存して`Authorization: Bearer`で下記APIを呼ぶ。30秒ごとに自動更新。スマホ幅対応、日本語、JST表示。
- `GET /v1/dashboard?date=YYYY-MM-DD`（JSTの日付。省略で全期間）: 専用シークレット`DASHBOARD_TOKEN_SHA256`のトークンだけで認証（端末トークンでは不可、ダッシュボード用トークンで書き込みAPIは不可）。
- 応答: `{schema_version:1, date, totals:{net_sales, orders, cancelled_orders, cancelled_amount, average}, by_hour:[{hour(0-23 JST), sales, orders}], by_product:[{id, name, quantity, sales}], segments:[{age, gender, orders, sales}]（未設定はnull）, stock:[{id, name, active, stock, sold}], devices:[{device_id, device_label, orders, sales, last_received_at}], sessions:[{id, device_label, opened_at, closed_at, float_total, expected_total, counted_total, difference, sales_total, cancel_total, order_count}]}`。
- 表示: 合計カード、時間帯別売上グラフ、商品別（数量・売上）、客層（年代×性別の表）、在庫（少ない順、0以下は強調）、端末別、レジ締め一覧（差額強調）。外部ライブラリなし（素のSVG/HTML）でよい。

## 端末側

### DB v3（両OS同一）

- `orders`に `device_id TEXT, customer_age TEXT, customer_gender TEXT` を追加。
- `products`に `active INTEGER NOT NULL DEFAULT 1, track_stock INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 0, cloud_stock INTEGER, dirty INTEGER NOT NULL DEFAULT 1` を追加（既存商品は未送信=dirty 1, version 0）。
- 新表 `stock_events(id TEXT PRIMARY KEY, product_id TEXT NOT NULL, kind TEXT NOT NULL, quantity INTEGER NOT NULL, reason TEXT, created_at TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0)`。
- 新表 `drawer_sessions(id TEXT PRIMARY KEY, opened_at TEXT NOT NULL, closed_at TEXT, float_json TEXT NOT NULL, float_total INTEGER NOT NULL, counted_json TEXT, counted_total INTEGER, expected_total INTEGER, sales_total INTEGER, cancel_total INTEGER, order_count INTEGER, synced INTEGER NOT NULL DEFAULT 0)`。開いているセッションは端末に最大1つ。
- `sync_metadata`: `device_id`, `feed_after`（整数文字列）。

### 自動同期サイクル（既存の単一実行ロック・syncGateを共有）

1回のサイクル = ①dirty商品の送信（/v1/products）→ ②未送信の在庫イベント（/v1/stock）→ ③未送信のレジセッション（/v1/sessions）→ ④未同期の注文（既存の/v1/sync、50件）→ ⑤フィード取り込み（/v1/feed、has_moreの間最大5ページ）。どこかで失敗したらそこで止め、既存どおりsyncGateに待機時間を保存。成功時のgateは既存どおり5秒（競合時300秒）。

- トリガー: 既存（会計・取消後、起動・前面復帰、設定保存後）＋商品編集・在庫調整・レジ開け/締めの後＋**前面にある間60秒ごと**（フィードで他端末の売上と在庫を取り込むため。DBのポーリングはしない）。
- ①の結果: `applied`→ローカルをサーバー値で上書きしdirty=0。`conflict`→サーバー値を採用しdirty=0（「商品○○は他の端末の変更を優先しました」をメッセージに出す）。
- ②の結果: accepted/rejectedともsynced=1。返った商品の在庫を`cloud_stock`へ。
- ⑤の適用（1ページ1トランザクション、`feed_after`も同じトランザクションで保存）:
  - 商品: ローカルがdirtyでなければ name/price/active/track_stock/version/cloud_stock をサーバー値で上書き（無ければ作成、dirty=0）。dirtyなら触らない（次の①で解決）。
  - 注文: 既存の復元マージと同じ規則（無ければsyncedとして挿入、取消の単調性、内容が違えば端末の内容を保持）。自端末の注文が戻ってきても内容一致で何もしない。
- 表示在庫 = `cloud_stock` − 端末の未同期注文（revision 1で未送信）の数量 + 未同期の取消分 − 未送信のaddイベント…ではなく、簡易に「cloud_stock − 未同期（synced_revision<revision かつ取消されていない）注文のその商品の数量」。`track_stock=0`は表示しない。

### レジ画面

- 商品ボタン: `active=0`は非表示。`track_stock=1`なら「残りN」を表示、N≤0は「売り切れ」で押せない。
- 客層: 年代4ボタン＋性別3ボタン（単一選択）。両方選ぶまで「会計を確定」は押せない。会計後にリセット。
- 預り金ボタン: 「ちょうど」「1,000円」「5,000円」「10,000円」（その額をセット）と「+100」「+500」「+1,000」（加算）「クリア」。手入力欄も残す。
- 釣銭の内訳: 確認ダイアログとレシート表示に、お釣りの金種内訳（大きい金種から貪欲、2000円札は使わない）を表示（例「1,000円札×1・100円玉×3」）。

### 商品画面

- 追加・編集で 名前・価格・販売中/停止（active）・在庫管理する（track_stock）を編集。保存はローカル（dirty=1）→自動同期。
- 在庫管理する商品は「在庫を数えて設定」（set）と「入荷を追加」（add）の操作。stock_eventsへ追加→自動同期。
- 一覧に在庫（表示在庫）を出す。

### 締め（新タブ「締め」。タブ順: レジ・商品・履歴・締め・同期）

- 開いているセッションが無い: 「レジ開け」— 金種ごとの釣銭準備金の枚数入力（＋/−と数値入力）、合計表示、開始。
- 開いている: 開始時刻、準備金、セッション中の売上・取消・件数、**現金在高（理論値）= 準備金 + セッション中に作成された有効な会計の合計 − セッション中に記録した取消の合計**（取消は返金として現金から出る）。客層別の件数。
- 「レジ締め」: 金種ごとの実査枚数入力 → 実際の合計・理論値・差額を表示 → 確定でcounted/expected/各合計を保存してclosed_at記録 → 自動同期。締め後は新しいレジ開けが可能。
- セッション未開始でも会計はできる（ブロックしない）。その会計はどのセッションにも入らない（作成時刻で判定: opened_at ≤ created_at < closed_at）。

### 同期画面

- 既存の表示に「最終取り込み時刻」と「端末名」を追加。復元・バックアップは残す。

## テスト

- Worker: 既存15件を壊さない。追加: 旧ペイロードの再送が競合にならない、任意フィールドの検証、在庫の派生値（販売・取消・add/set、並行再送で二重計上しない）、products の作成/更新/競合/冪等、stock の冪等とset、sessions の冪等と締め後不変、feed のseq順・512KiB切り・has_more、dashboard の認証分離（端末トークン不可）と集計値。
- Android: 単体テスト（釣銭内訳、表示在庫、セッション理論値の計算を純関数にしてテスト）。実機/エミュレータE2Eは別途。
- iOS: Coreの純関数テスト（同上）を`ios/Tests`に追加。

## 改訂 2026-11-21（レビュー反映。上の記述より優先）

1. **同期サイクルの順序**: ④注文 → ①商品 → ②在庫 → ③レジセッション → ⑤フィード。注文を先に送り、棚卸（set）の差分計算に自端末の販売が反映された後にする。
2. **手順ごとの隔離**: ①②③でHTTP 400（内容不正）が返ったら、その送信分の各項目に保留フラグ（`sync_error='rejected'`）を永続化して自動送信から外し、同期画面に「送信できなかった商品/在庫/レジ記録 N件」を出して次の手順へ進む。通信失敗・5xxは従来どおりサイクルを止めてsyncGateに待機時間を保存。401/403はサイクルを止め、設定保存か手動送信まで**全ての**自動トリガー（会計後・定期を含む）を止める。
3. **競合した注文**: `sync_error='conflict'`を永続化して自動送信から外す（定期の取り込みは止めない）。手動の「今すぐ送信」は`conflict`を解除して1回だけ再送する。
4. **取消の記録端末**: 端末DBの`orders`に`cancelled_here INTEGER NOT NULL DEFAULT 0`（v3に含める。ペイロードには載せない）。この端末で取消を記録したときだけ1。復元・取り込みでは0のまま。
5. **理論値**: 準備金 + セッション中に作成された**自端末（device_id = 自端末）**の会計合計 − セッション中に**この端末で記録した取消**（`cancelled_here=1`かつcancelled_atがセッション内）の合計。両OSで同じ。負数もあり得る。
6. **文字数**: 商品名・在庫メモ・取消理由・端末名などの上限はすべてUnicodeコードポイント数で数える（Worker・Android・iOSで統一）。端末名は64コードポイントで切る。
7. **Worker**: `/v1/sessions`の`expected_total`は−1,000,000,000〜1,000,000,000の整数を許す。`/v1/products`で行が無く`base_version>0`のときは新規作成（version 1、`applied`）とし、`product`がnullの応答を返さない。
8. iOSのカート数量も表示在庫を上限にする（Androidと同じ）。

## 改訂2 2026-11-21（在庫は常に管理・マイナス許容。上の記述より優先）

ユーザー決定: 在庫管理は常にオン、マイナス在庫を許容する。

1. **在庫は全商品で常に管理**する。`track_stock`のスイッチはUIから削除。在庫 = `SUM(在庫イベントdelta) − SUM(有効な販売数量)`を全商品で計算し、フィード・products応答・ダッシュボードの`stock`は常に整数（nullにしない）。新規商品は0から始まる。
2. **商品ごとの`stop_at_zero`（在庫0で販売を止める）**: 既定false。falseなら表示在庫が0以下でも販売でき、在庫は負数になる（「在庫 −3」を警告色で表示）。trueなら表示在庫≤0で「売り切れ」として押せない（従来の動き）。カート数量の上限もtrueの商品だけ表示在庫まで。
3. **Worker / D1**: migration `0004_stock_always.sql`で`cloud_products`に`stop_at_zero INTEGER NOT NULL DEFAULT 0`を追加し、既存行の`track_stock`を1にする。`/v1/products`は`stop_at_zero`（bool、省略時false）を受け付け、内容比較・versionの対象に含める。`track_stock`は受け付けても無視し、応答では常に`true`を返す（0.4.0初期ビルドとの互換）。`/v1/stock`の`stock_not_tracked`による拒否は廃止。ダッシュボードの在庫は全商品、負数を強調。
4. **端末DB v3**（未リリースなのでv3のまま変更）: `products`に`stop_at_zero INTEGER NOT NULL DEFAULT 0`。`track_stock`列は残すが常に1として扱う。在庫イベントは全商品で作成可。
5. 「在庫未取得」（cloud_stockがnull）の商品は0とみなさず、従来どおり在庫表示なしで販売可。

## UI改訂 2026-11-21（ユーザー指示。上の記述より優先）

ユーザー指示: デバッグ用の設定は表に出さない。基本は自動同期。エクスポートは右上のアイコン。読み込み中は豆腐のアイコン。配色はSlack「#99_豆腐大豆き」（Matrix経由で取得）の今年の素材から。

### 配色（2026「Are you Tofu?」炭火の豆腐田楽。メニュー・立て看板ポスター・フォトフレームの実色から抽出）

| 役割 | ライト | ダーク |
|---|---|---|
| 背景・面（紙の白） | `#F8F7F6` | `#2E2018` |
| 面の段差（カード） | `#FFFFFF` | `#3B2A20` |
| 文字（胡麻・焦げ） | `#2E2018` | `#F6F4F3` |
| 主色（味噌の飴色、主ボタン） | `#B66427`（文字`#FFFFFF`） | `#D18C53`（文字`#2E2018`） |
| 主色の淡い面 | `#F3DCC6`（文字`#503225`） | `#503225`（文字`#F3DCC6`） |
| 副色（濃い味噌） | `#503225` | `#CB8D59` |
| 補助（灰茶・枠線・補足文字） | `#635954` | `#ADA29C` |
| アクセント（豆腐の上面） | `#FFE8A9` | `#FFE8A9` |
| 警告（在庫マイナス等） | `#B66427`系ではなく既存のエラー色を使う |

AndroidはMaterial 3のColorSchemeへ、iOSはアクセントカラーと背景・カードに反映する。アイコン（緑背景）は今回変えない。

### 画面構成

- **同期タブを廃止**し、タブは「レジ・商品・履歴・締め」の4つにする（iOSと揃う）。
- 全画面の上部バー右上に**同期状態アイコン**（クラウド。未同期0なら「同期済み」、未同期ありなら件数バッジ、失敗・保留ありなら警告表示）。タップで**同期シート**を開く: 未同期件数、最終送信・最終取り込み時刻、最後のメッセージ、保留件数、「今すぐ送信」、そして小さく「詳細設定」。
- **詳細設定**（別画面、通常は開かない）: 接続設定（URL・トークン）、設定ファイルの読み込み、商品バックアップ、クラウドから復元・続きの復元、端末名・端末ID。ここだけにデバッグ的な操作を置く。
- **履歴**: 上部バー右上に**エクスポート（CSV）のアイコン**ボタン。本文中の「全件をCSVに書き出す」ボタンは削除。
- 上部バーは狭い画面（横向き・小画面）でも消さない（タイトルは省略してよいがアイコンは残す）。

### 読み込み中の表示

- 既存の`LoadingIndicator`（Android）/`ProgressView`（iOS）を、**豆腐マークのアニメーション**に置き換える。豆腐マークは`shared/branding/tofu-mark.svg`（白い上面・`#FFE8A9`の右面の六角形の豆腐）と同じ形。Androidは既存の`drawable/ic_tofu_foreground.xml`を使い、iOSはSwiftUIのPathかアセットで同形を描く。動きは上下にぷるんと弾む（スケールY 1.0↔0.85、0.8秒周期）程度で、`prefers reduced motion`/アクセシビリティの「視差効果を減らす」では静止表示。

### 既定で自動同期（接続設定の同梱）

- 新規インストールでも設定なしで自動同期が始まるよう、**ビルド時に接続設定（URL・端末トークン）を同梱**できるようにする。保存済みの接続設定があればそちらを優先、無ければ同梱設定を使う。同梱設定はソース管理に入れないファイルから読む:
  - Android: ビルドタイプ別アセット `android/app/src/<buildType>/assets/sync-default.json`（`{"url":..., "token":...}`）。`debug`（本番で使っている）と`synctest`で別ファイル。`.gitignore`に追加。無ければ同梱なし（従来どおり手動設定）。
  - iOS: `ios/Config/sync-default.json` があればバンドルに含める（project.ymlでoptional resource）。`.gitignore`に追加。
- 同梱設定を使う場合も、同期先の固定（bindSyncTarget）など既存の規則は同じ。

## 単品レジ画面 2026-11-21（ユーザー決定。上の記述より優先）

モックアップ: `docs/single-product-mockup.html`。

1. **自動切り替え**: 販売中（active）の商品がちょうど1つのとき、レジタブは単品画面になる。2つ以上なら従来の画面。
2. **商品カード**（モックのA＋C）: 豆腐マーク・商品名・単価・在庫表示（既存の在庫表示規則、`stop_at_zero`の売り切れ規則もそのまま）と、大きな−／本数／＋。本数の下に合計額。本数の初期値は1、会計後は1に戻す。上限は既存（999、`stop_at_zero`なら表示在庫）。
3. **客層**（Aのチップ、年代4・性別3）: **任意**。未選択でも確定できる。選んだものは再タップで解除できる。→ この変更は従来の複数商品画面にも適用し、「客層を選ぶと会計を確定できます」の制約を外す（未選択の会計は`customer_age`/`customer_gender`をnullで送る）。
4. **受け取った額**（C）: 「ちょうど」「1,000」「2,000」「5,000」「10,000」「手入力」の3列グリッド。**本数を変えるたびに「ちょうど」が自動選択**される。額ボタンは預り金をその額にセット（合計未満の額は押せない＝無効表示）。「手入力」は数値入力欄を開く。
5. **お釣り**: 大きな表示（`#FFE8A9`の面）。下に金種内訳と預り金。
6. **確定**: 「確定して次へ」1タップで保存（**確認ダイアログなし**、レシートダイアログも出さない）。保存後、画面下に通知（Snackbar/トースト）「¥1,000（2本）を保存しました・お釣り ¥4,000」を約6秒表示し、「取消」を押すとその会計を全額取消（理由「確定直後の取消」、`cancelled_here=1`）として記録する。二度押しで二重会計にならないこと（既存の会計ID冪等性と、保存中のボタン無効化）。
7. 単品画面でも会計は通信を待たない・自動同期は既存どおり。

## 商品写真 2026-11-21（ユーザー決定「2: 商品ごとに写真を設定し全端末へ配る」。上の記述より優先）

保存先はD1（現行トークンにR2権限が無いため）。写真は端末で縮小してから送る。

### Worker / D1（migration `0005_product_images.sql`、追加のみ）
- `cloud_images(shop_id TEXT NOT NULL, hash TEXT NOT NULL, content_type TEXT NOT NULL, bytes BLOB NOT NULL, size INTEGER NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(shop_id, hash))`
- `cloud_products`に`image_hash TEXT`（null=写真なし）。
- `POST /v1/images`: 端末トークン。本文は画像そのもの（`Content-Type: image/jpeg`のみ許可、最大512KiB）。サーバーでSHA-256（小文字16進）を計算し、`INSERT OR IGNORE`（同じ内容の再送は書き込みなし）。JPEGの先頭（FF D8 FF）を検証。応答`{schema_version:1, hash, size}`。
- `GET /v1/images/<hash>`: 端末トークン**または**ダッシュボード用トークン（読み取り）で取得。`Content-Type: image/jpeg`、`Cache-Control: private, max-age=31536000, immutable`、`ETag: "<hash>"`。無ければ404。
- `/v1/products`: 各商品に`image_hash`（64桁16進またはnull、省略時はnull…ではなく**省略時は変更なし扱いにしない**：内容比較・versionの対象として扱い、省略はnull）。指定されたhashの画像が`cloud_images`に無ければその商品は400（端末は画像を先に送る）。フィード・products応答・ダッシュボードの商品に`image_hash`を含める。
- ダッシュボード: 在庫・商品別の行に小さなサムネイル（`/v1/images/<hash>`をダッシュボードトークンでfetchしてblob URL表示）。

### 端末
- DB v3（未リリースのため変更可）: `products`に`image_hash TEXT`。新表`local_images(hash TEXT PRIMARY KEY, uploaded INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)`。画像ファイルはアプリ専用領域の`product-images/<hash>.jpg`に保存（DBにはBLOBを入れない）。
- 商品編集: 「写真を選ぶ」（Android: Photo Picker `PickVisualMedia`、iOS: `PhotosPicker`（iOS 16））と「写真を外す」。選んだ画像は長辺800px・JPEG品質80で縮小し（EXIF・位置情報は持ち出さない）、SHA-256を計算してファイル保存、`local_images`に未送信で登録、商品の`image_hash`を設定してdirty=1。
- 同期サイクル: 「注文 → **画像** → 商品 → 在庫 → レジセッション → フィード」。画像は未送信の`local_images`を1回のサイクルで最大5枚`POST /v1/images`し、成功したら`uploaded=1`。400（形式不正など）はその画像を保留（再送しない）し、その画像を参照する商品の送信も保留。
- 取り込み: フィード・products応答で受けた`image_hash`の画像がローカルに無ければ`GET /v1/images/<hash>`で取得して保存（1サイクル最大10枚、失敗は次回）。使われなくなった画像ファイルは起動時に掃除してよい。
- 表示: 単品画面の商品カードは写真があれば写真（角丸、無ければ豆腐マーク）。複数商品画面の商品ボタン・商品一覧にも小さな写真。
- 写真の取得・送信の失敗は会計をブロックしない。

### 初期データ
- 田楽豆腐の写真: `shared/branding/dengaku-tofu-square.jpg`（Slack「#99_豆腐大豆き」2026-11-18の商品画像を正方形・800pxに加工済み）。本番の商品が作られた後、こちらで設定する。

## 本番／テストの切り替え 2026-11-21（ユーザー指示。上の記述より優先）

- 常設のテスト環境: Worker `tofu-pos-v3-sync-staging`（https://tofu-pos-v3-sync-staging.gapul.workers.dev）、D1 `tofu-pos-v3-staging`、`SHOP_ID=tofu-test`、本番と別の端末トークン・ダッシュボードトークン（`wrangler.jsonc`の`env.staging`）。本番トークンはテストでは401。
- アプリに**環境**（`production`＝本番 / `test`＝テスト）を持つ。既定は本番。
- **環境ごとに完全に分離**: 端末DBファイル（本番`tofu-pos.sqlite`、テスト`tofu-pos-test.sqlite`）、商品写真フォルダ（`product-images/`と`product-images-test/`）、保存済み接続設定（Android: SharedPreferencesキーとKeystore別名、iOS: Keychainのaccount）、同梱の既定接続（`sync-default.json`と`sync-default-test.json`）、同期先の固定・待機時間・取り込み位置。片方の会計・商品・在庫・レジ記録がもう片方へ出たり送られたりしない。
- 切り替えは**詳細設定**の「環境」から。同期・保存処理の実行中は不可。確認ダイアログ（「テスト環境に切り替えます。テストの売上は本番に入りません」/「本番環境に戻します」）のあと、現在の画面状態（カート等）を破棄して、もう一方のDBで読み込み直す。選んだ環境は端末に保存し、再起動後も維持。
- **テスト環境中は常に目立つ表示**: 上部バーに「テスト」バッジ（警告色）を出し、上部バーの背景も通常と変える（Android: errorContainer系、iOS: オレンジ系）。同期シートと会計の保存通知にも「テスト」と出す。本番のときは何も出さない。
- 同期・自動同期・取り込みは、現在の環境の設定・DBだけを使う（切り替え時に実行中の予約・タイマーは止め、新しい環境で起動し直す）。
- `synctest`ビルドはそのまま残す（既定接続はテスト環境のものを同梱）。

## 客層「グループ」2026-11-21（ユーザー指示。上の記述より優先）

- 客層に3つ目の軸 `customer_group` を追加: `solo`（一人）/ `friends`（友人）/ `family`（家族）/ `couple`（カップル）/ `group`（グループ）。年代・性別と同じく**任意**、再タップで解除、チップの並び順はこの順。
- 注文ペイロードの任意フィールド。Workerの`normalize`はnull/未指定なら出力に含めない（既存の会計のハッシュを変えない）。不正値は400。base_hashにも含める。
- D1 migration `0006_customer_group.sql`（追加のみ）: `cloud_orders`に`customer_group TEXT`、既存行はpayloadから埋める。ダッシュボードに「グループ別」（件数・売上、未設定を含む）を追加し、`/v1/dashboard`の応答に`groups:[{group, orders, sales}]`。
- 端末DB: **v3はリリース済み**（Pixel・iPhoneが使用中）なので **v4** にし、v3→v4で`orders`に`customer_group TEXT`を追加（データを消さない。v1/v2からも通る）。
- UI: 単品画面・複数商品画面とも、年代・性別の下に3行目として5つのチップ。1行に収まるよう文字を小さくしてよい（「カップル」「グループ」が折り返さないこと。狭い画面では縮小）。確認ダイアログ・レシート・履歴の客層表示にもグループを含める。
- 締めタブの客層別件数にもグループ別を出す。

## 釣銭内訳の廃止・客層の横送り 2026-11-21（ユーザー指示。上の記述より優先）

1. **お釣りの金種は問わない**: レジ（単品・複数商品）・確認・保存通知・レシートから「100円玉×2」などの釣銭内訳の表示を削除し、お釣りの金額だけを出す。レジ開け・締めの金種別枚数入力はそのまま残す。釣銭内訳の純関数とテストは不要なら削除してよい。
2. **客層は「年齢」「性別」「集団」の3つに分ける**（見出しをこの名前に。「集団」が前項の`customer_group`＝一人/友人/家族/カップル/グループ）。
3. **横送りのカード**: 客層は1枚のカード内で、1軸ずつ横に並ぶページ（年齢 → 性別 → 集団）として表示する。上部に「年齢・性別・集団」のタブ風インジケーター（選択済みの軸は選んだ値を小さく表示、タップでそのページへ移動）。
   - チップを押して選ぶと、**自動で次の軸のページへスクロール**する（年齢→性別→集団）。集団を選んだら、画面全体を「受け取った額」（単品）または合計・確定（複数商品）が見える位置へスクロールする。
   - 選択済みのチップを再タップすると解除のみ（スクロールしない）。指で左右にスワイプしても移動できる。
   - 会計後は年齢ページに戻し、選択をすべて解除。
   - 客層は引き続き任意（どこまで選んでも、選ばなくても確定できる）。
   - アニメーションを減らす設定ではアニメーションなしで切り替える。
4. **手入力のフォーカス**: 「受け取った額」の「手入力」を押した瞬間に、預り金の入力欄を表示してフォーカスを当て、数字キーボードを開く（Android: FocusRequester＋キーボード表示、iOS: @FocusState）。入力欄は空の状態から打てる（既存の額を残さない）。確定またはほかの額ボタンでキーボードを閉じる。

## 整理番号 2026-11-21（ユーザー指示。上の記述より優先。「整理券は追加しない」は撤回）

- 会計ごとに**整理番号**を発行する。番号は「端末の接頭辞＋その端末の当日の連番」。連番はJSTの日付が変わると1に戻る。接頭辞は詳細設定で端末ごとに設定（英大文字1〜2文字、既定は空）。表示例: 接頭辞なし「12」、接頭辞A「A-12」。オフラインでも会計時に即発行（クラウドに問い合わせない）。
- 連番は会計の保存と**同じトランザクション**で採番する（`sync_metadata`に`ticket_date`/`ticket_seq`を保持）。同じ会計IDの再保存（冪等）では新しい番号を取らない。取消しても番号は戻さない。環境（本番/テスト）ごとに別カウンター。
- 注文ペイロードに任意フィールド`ticket_no`（文字列、1〜8文字、`[A-Z]{0,2}-?[0-9]{1,4}`程度）。Workerの`normalize`はnull/未指定なら出力に含めない（既存会計のハッシュ不変）、base_hashに含める。D1は**0006に含める**（まだ未配備のため）: `cloud_orders`に`ticket_no TEXT`。ダッシュボードの最近の会計等に表示してよい。
- 端末DB: **v4に含める**（未リリース）: `orders.ticket_no TEXT`。
- 表示: 単品画面の保存通知に大きく「整理番号 12」、複数商品画面のレシートダイアログに大きく表示、履歴の各会計にも表示。CSV書き出しにも列を追加。

## iPad・Mac対応 2026-11-21（ユーザー指示）

- **iPad**: `TARGETED_DEVICE_FAMILY: '1,2'`は既存。横幅が広い（`horizontalSizeClass == .regular`）ときのレイアウトを追加:
  - 複数商品のレジは2列（左: 商品グリッド、右: カート・客層・受け取った額・合計・確定）。
  - 単品画面・締め・履歴・商品・同期シート・詳細設定は、中央寄せで最大幅（約640pt）に収める。単品画面は横向きなら左に商品カード、右に客層・受け取った額・お釣り・確定の2列でもよい。
  - 全方向の回転に対応（iPadのマルチタスク要件: `UISupportedInterfaceOrientations~ipad`に4方向、`UIRequiresFullScreen`は付けない）。
- **Mac**: **Mac Catalyst**（`SUPPORTS_MACCATALYST: YES`、`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD`は使わない）。バンドルIDはiOSと同じ`dev.gapul.tofupos.v3`（App Store Connectで同じアプリとして扱う。`DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO`）。
  - iPadのregularレイアウトを使う。ウィンドウ最小サイズを設定（例: 900×640）。
  - 数字キーボードの代わりに物理キーボードで預り金を入力できること。Return/Enterで「確定して次へ」（単品画面）を実行できるとよい。
  - Catalystで使えないAPI（`UIDevice.current.name`の扱い、`keyboardType`など）は`#if targetEnvironment(macCatalyst)`で分岐。Keychain・SQLite・PhotosPickerはCatalystでも同じ。サンドボックス（App Sandbox）を有効にし、ネットワーク送信（`com.apple.security.network.client`）とユーザーが選んだファイルの読み書き（`com.apple.security.files.user-selected.read-write`、CSV書き出しと設定ファイル読み込み用）の権限を付ける。
  - アプリアイコンはmacOSでも表示される（既存の1024pxから）。

## 購入ボタン・余白 2026-11-21（ユーザー指示）

- 単品画面の「確定して次へ」を**「購入」**に改名（両OS）。複数商品画面の「会計を確定」も「購入」に揃える（確認ダイアログの「確定する」はそのまま）。
- 「購入」で保存したら、レジ画面を**一番上までスクロール**して戻す（商品カード・本数が見える状態。単品・複数商品とも）。アニメーション無効設定では即時。
- iOS: 上部の余白が大きすぎる。全タブのナビゲーションタイトルを`.inline`表示にして、上部の空きを詰める（ナビゲーションバー右上の同期アイコン・テストバッジ・エクスポートアイコンは維持）。iPad/Macも同様。

## 受け取った額の初期状態 2026-11-21（ユーザー決定。上の「本数を変えるたびにちょうど自動選択」を撤回）

- 単品画面の「受け取った額」は**最初は何も選ばない**。本数を変えたとき・購入後も未選択に戻す（手入力の値も消す）。
- 未選択のあいだは「購入」を押せない（無効表示）。お釣り欄は「—」と「受け取った額を選んでください」。
- 「ちょうど」「1,000」等や「手入力」を押すと選択され、もう一度同じボタンを押すと未選択に戻す。合計未満の額は従来どおり押せない。

## 説明文の削減 2026-11-21（ユーザー指示）

- 画面上の**仕組みの説明文・補足文は原則削除**（例:「会計は通信を待たずに端末へ保存します」「売上はこの端末に保存し、自動で…」「CSVは確認用です…」「商品バックアップは新しい順に…」「本番とテストは…完全に分かれています」「この端末の会計だけを数えます…」「過去の会計とカートの単価は変わりません…」など）。
- 残すもの: ボタン・入力欄・見出しのラベル、エラー・警告、取消/レジ締め/環境切り替えなど取り返しのつかない操作の確認文（1文に短縮）、テスト環境の表示、空の画面の一言（「商品を登録してください」程度の短文）。
- 確認ダイアログの本文は1文、ラベルは短く（例:「受け取った額を選んでください」はそのまま可）。同期シートは件数・時刻・状態・ボタンだけ。
- 両OSで同じ方針。文言を変えたテストは更新。

## アイコンボタン化 2026-11-21（ユーザー指示）

- 原則: **文字だけのボタンはアイコンだけのボタンにする**（保存・戻る・閉じる・キャンセル・確定・今すぐ送信・詳細設定・CSV書き出し・写真を選ぶ/外す・在庫を数える・入荷を追加・取消・本数±・レジ開け・レジ締め・バックアップ・復元・続きの復元・設定ファイル読み込み・環境切り替え 等。ダイアログのボタンも）。
- 例外（文字を残す）: 金額のボタン（ちょうど・1,000…・手入力）、客層の選択肢、商品ボタン、「購入」（ユーザー確認中。決まるまで文字のまま）、テスト環境バッジ。
- アイコンは `shared/branding/ui-icons/`（Codex作の店用セット。SVG/Android XML）を優先し、無いものはMaterial Symbols（Android）/SF Symbols（iOS）で。
- アクセシビリティ: すべてのアイコンボタンに読み上げラベル（contentDescription / accessibilityLabel）を付け、長押しで名前のツールチップ（Android: TooltipBox/PlainTooltip、iOS: .help と contextMenu 等）を出す。タッチ領域は48dp/44pt以上。
- 破壊的操作（取消・レジ締め・環境切り替え・復元）は、アイコンでも確認ダイアログを残す（ダイアログの確定/キャンセルもアイコン＋色で区別: 確定=チェック、キャンセル=×）。

## アイコンだけのボタンの見直し 2026-11-21（ユーザー指示「アイコンだけで何かわからないボタンをなくして」）

- アイコンだけにしてよいのは、意味が誰にでも明らかなものだけ: ＋／−（本数・枚数）、×（閉じる・キャンセル）、✓（保存・確定）、戻る矢印、同期状態アイコン（右上）、タブ（ラベル付き）。
- それ以外のボタンは **アイコン＋短い文字**（例:「⇩ CSV」「⚙ 詳細設定」「⟳ 今すぐ送信」「写真」「在庫を数える」「入荷」「取消」「レジ開け」「レジ締め」「バックアップ」「復元」「続きを復元」「設定ファイル」「環境切り替え」）。文字は2〜6字程度。
- ダイアログの確定/キャンセルも、✓/×に「確定」「戻る」などの文字を添える（iOSの標準アラートは文字のまま）。
- 写真が未取得の商品は、画面に表示するときにもダウンロードを試みる（同期サイクルの外でも、前面復帰時に未取得の写真を取りにいく）。

## 引っ張って更新 2026-11-21（ユーザー指示）

- レジ・商品・履歴・締めの各画面で、上から下へ引っ張ると**再読み込み**（Android: PullToRefreshBox、iOS: `.refreshable`）。動作は「今すぐ送信」と同じ同期サイクル1回（送信＋取り込み＋未取得写真の取得）と、画面の読み直し。
- 更新中の表示は豆腐マークのアニメーション（既存の読み込み表示）に合わせる。待機時間（syncGate）中や同期中は、同期は走らせず画面の読み直しだけして、すぐ閉じる。401/403で自動同期停止中でも手動扱いで1回試す（手動送信と同じ規則）。

## テスト環境のデータ消去 2026-11-21

- テスト用D1（`tofu-pos-v3-staging`）を空にして、本番と同じ商品「豆腐田楽」¥500・写真つき・在庫114を入れた（端末の取り込み位置より後になるよう seq=1000 から）。
- 端末側: **テスト環境のときだけ**、詳細設定に「テストデータを消去」（アイコン＋文字）を置く。確認1回のあと、テスト環境の端末DB・写真フォルダ・テストの接続状態（同期先固定・取り込み位置・待機時間・整理番号）を消して作り直し、テスト用クラウドから取り込み直す。本番のデータには一切触れない。

## 客層「関係」2026-11-21（ユーザー指示）

- 客層に4つ目の軸 `customer_relation`（見出し「関係」）: `acquaintance`（知り合い）/ `relative`（親族）/ `member`（メンバー）/ `tofu_fan`（豆腐狂）/ `general`（一般人）。この順。**任意**、再タップで解除。
- 横送りのページは「年齢 → 性別 → 集団 → 関係」。関係を選んだら受け取った額（単品）／合計（複数）へスクロール（今までの「集団の後」の動きを「関係の後」へ移す）。インジケーターにも4つ目。
- 注文ペイロードの任意フィールド（null/未指定は出力しない、不正値は400、base_hashに含める）。D1 migration `0007_customer_relation.sql`（追加のみ、`cloud_orders.customer_relation`、payloadから埋める）。ダッシュボードAPIに `relations:[{relation, orders, sales}]` と画面に「関係別」表。修復SQLにも反映。
- 端末DB: **v4はリリース済み**なので **v5**（v4→v5で `orders.customer_relation` を追加、データを消さない）。確認・レシート・履歴・締めの客層表示にも含める。
