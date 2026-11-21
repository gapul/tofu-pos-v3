# Cloudflare売上同期API

WorkersとD1だけを使う1店舗用の売上同期API（0.4.0: 複数端末の取り込み・商品マスタ・在庫・レジ締め・ダッシュボード）。アプリは会計・取消のたびに自動で同期し（失敗時は永続化した待機時間で再送）、会計は端末内で完結する。D1は最新の会計状態を集約する保存先で、レジ起動や会計の必須経路にはしない。

## 検証

Node.js 22.13以上の組み込みSQLiteで、D1のSQLを実際に実行する。

```sh
pnpm install
pnpm test
pnpm exec wrangler deploy --dry-run
```

テストは全migrationを順に適用したDBで、100回の同一再送・取消の巻戻し防止・内容競合・店舗分離・50件バッチのDBアクセス数・不正トークン・過大サイズ・DB障害時の無再試行・同時更新の競合を確認する。0.4.0分は、0.3.0の行をmigration 0003で移行した後の再送が競合しないこと、任意フィールドの検証、在庫の派生値（販売・取消・add/set、並行再送で二重計上しない）、商品の作成/更新/競合/冪等、在庫イベントの冪等とset、レジセッションの冪等と締め後不変、フィードのseq順・512KiB切り・has_more、ダッシュボードの認証分離と集計値、migration 0004で既存商品が全て在庫管理になり再配信されること、`stop_at_zero`のversion管理と`track_stock`の無視、修復SQLの冪等性、商品写真（JPEG検証・冪等アップロード・両トークンでの取得・ETag/304・未登録hashの拒否・image_hashのversion管理）、客層グループ・整理番号・関係（検証・base_hash・既存会計のハッシュ不変・migration 0006の埋め戻し・ダッシュボード表示）を確認する。Wranglerは開発用依存のみ。esbuildとworkerdの固定バージョンのビルドスクリプトだけを許可する。

## 配備

`wrangler.jsonc`のアカウントとD1は作成済み。別アカウントに配備する場合は、専用D1を新規作成して設定を差し替える。既存DBを流用しない。

初回はシークレットを登録する。

```sh
pnpm exec wrangler secret put DEVICE_TOKEN_SHA256
pnpm exec wrangler secret put DASHBOARD_TOKEN_SHA256
```

0.4.0への更新は「migration → 即deploy → 修復SQL」の順で続けて行う。

```sh
pnpm exec wrangler d1 migrations apply tofu-pos-v3 --remote                      # 1. 0003_v4.sql
pnpm exec wrangler deploy                                                         # 2. 直後に0.4.0のWorker
pnpm exec wrangler d1 execute tofu-pos-v3 --remote --file repair/0003_after_deploy.sql  # 3. 修復
```

### 客層「関係」（migration 0007）への更新

本番・テスト環境とも0006まで適用済み。0007は`customer_relation`列の追加とpayloadからの埋め戻しだけで、手順は0006と同じ（各環境でmigration → 直後にdeploy）。

```sh
pnpm exec wrangler d1 migrations apply tofu-pos-v3 --remote && pnpm exec wrangler deploy
pnpm exec wrangler d1 migrations apply tofu-pos-v3-staging --remote --env staging && pnpm exec wrangler deploy --env staging
```

配備までの間に旧Workerが受けた注文の列は空のまま（payloadには残る）なので、必要なら0007の`UPDATE`を再実行して埋める。`repair/0003_after_deploy.sql`は0007適用後に使う。

### 客層グループ・整理番号（migration 0006）への更新

本番・テスト環境（`--env staging`、D1 `tofu-pos-v3-staging`）とも0005まで適用済み。0006は`customer_group`・`ticket_no`列の追加とpayloadからの埋め戻しだけ。両環境で同じ順に行う。

```sh
pnpm exec wrangler d1 migrations apply tofu-pos-v3 --remote                               # 本番 1. 0006
pnpm exec wrangler deploy                                                                  # 本番 2.
pnpm exec wrangler d1 migrations apply tofu-pos-v3-staging --remote --env staging         # テスト 1.
pnpm exec wrangler deploy --env staging                                                    # テスト 2.
```

新Workerは`customer_group`・`ticket_no`列に書くため0006を先に適用する。配備済みWorkerは0006適用後も動くが、その間に受けた注文の両列は空のまま（payloadには残る）。0006の2つの`UPDATE`は列が空でpayloadに値がある行だけを埋める冪等な文なので、必要なら`wrangler d1 execute ... --command`で同じ文を再実行して埋め直せる。`repair/0003_after_deploy.sql`も両列を埋めるようになったため、0006適用後に使う。

### 商品写真（migration 0005）への更新

本番は0004まで適用済み。0005は表と列の追加だけ。

```sh
pnpm exec wrangler d1 migrations apply tofu-pos-v3 --remote   # 1. 0005_product_images.sql
pnpm exec wrangler deploy                                      # 2. 直後に写真対応のWorker
```

新Workerは`image_hash`列と`cloud_images`を読むため0005を先に適用する。配備済みWorkerは0005適用後もそのまま動く。

### 改訂2（在庫は常に管理）への更新

本番は0003適用・0.4.0配備済み。0004は列の追加と`track_stock`の1化だけで、行を消さない。

```sh
pnpm exec wrangler d1 migrations apply tofu-pos-v3 --remote   # 1. 0004_stock_always.sql
pnpm exec wrangler deploy                                      # 2. 直後に改訂2のWorker
```

0004を先に適用する（新Workerは`stop_at_zero`列を読む）。配備済みの0.4.0 Workerは0004適用後も動く（`stop_at_zero`は既定0）。適用から配備までの間に旧Workerが`track_stock:false`で書いた商品は、新Workerが`track_stock`を無視して在庫を計算し、その書き込みでseqも進んでいるため、フィードで整数の在庫が届く。

0.4.0初回の配備時の注意: 0.4.0のWorkerは0003の列・表を使うため、migrationを先に適用する。0003適用後も0.3.0のWorkerは動く（追加列は既定値）が、その間に受けた注文は`seq=0`のままフィードに出ず、明細表・客層・端末の列も埋まらない。`repair/0003_after_deploy.sql`は`seq=0`の注文だけを対象に、明細を`cloud_order_lines`へ展開し、店舗の現在の最大値の後ろから`seq`を振り、`created_at`・端末・客層の列をpayloadから埋める。売れた商品は、フィードで在庫が届くようにseqを進める。0.4.0のWorkerが書いた行（seq>0）は変更しない。何度流しても結果は変わらない（2回目以降は何もしない）。途中で止まった場合も再実行でよい（作業用表`repair_0003_orders`は最後に削除される）。

ローカル確認（リモートには触れない）:

```sh
CI=true pnpm exec wrangler d1 migrations apply tofu-pos-v3 --local --persist-to /tmp/tos-worker-smoke
pnpm exec wrangler dev --local --port 8799 --persist-to /tmp/tos-worker-smoke \
  --var DEVICE_TOKEN_SHA256:<sha256> --var DASHBOARD_TOKEN_SHA256:<sha256>
```

配備用認証にはCloudflareのAccount API Token（Workers Scripts Edit・D1 Edit・Account Settings Read）を使える。環境変数`CLOUDFLARE_API_TOKEN`で渡し、ソース・設定JSON・ログ・アプリに保存しない。

`DEVICE_TOKEN_SHA256`には、ランダムに生成したレジ専用トークンのSHA-256小文字16進文字列を登録する。トークン原文だけを端末設定JSONの`token`に入れ、Workerはハッシュで照合する。端末設定は`{"url":"https://WORKER.workers.dev","token":"専用トークン"}`という形で、安全な経路で利用端末へ渡す。管理APIトークンはこのJSONに入れない。URLはHTTPSのホストだけを指定する。

`DASHBOARD_TOKEN_SHA256`には、端末用とは別に生成したダッシュボード専用トークンのSHA-256を登録する。ダッシュボード用トークンは`GET /v1/dashboard`だけに使え、端末用APIはすべて401。端末用トークンでは`/v1/dashboard`を読めない。未設定、または端末用と同じハッシュの場合、`/v1/dashboard`は503を返す。

## 同期の整合性

`POST /v1/sync`に最大50注文・256KiBを送る。`revision=1`は会計、`revision=2`は全額取消。新しい端末の初回送信が取消済みでも受け付ける。受領後にだけ`accepted`を返す。

同一注文ID・同一revision・同一内容の再送は読み取りのみ。古いrevision、同じrevisionで異なる内容、取消時の原金額変更は`conflicts`として返し、上書きしない。新規・更新の書き込みと受領内容の再確認はD1 batch内で行い、同時要求の競合でも原会計を書き換えない。

1リクエストの書き込みは最大50注文。正常な50件の初回送信はIDで絞った読取2回、同一再送は1回。認証・サイズ・形式が不正な要求はD1へ触れない。アプリは同時1実行と永続待機時間で送信を抑制する。WorkerはDB障害を503＋Retry-Afterで返し、アプリ内・Worker内で無限再試行しない。

## 保存先

- Workers: `tofu-pos-v3-sync`
- D1: `tofu-pos-v3`
- テーブル: `cloud_orders`, `cloud_order_lines`, `cloud_products`, `cloud_stock_events`, `cloud_sessions`, `cloud_catalogs`
- 店舗: `SHOP_ID=tofu`（リクエストからは変更不可）

`payload`に注文・明細・返金確認済み取消のスナップショットを保存する。`total_yen`は元の請求額で、取消行も消さない。純売上の集計例:

```sql
SELECT SUM(CASE WHEN cancelled=0 THEN total_yen ELSE 0 END) AS net_sales_yen
FROM cloud_orders WHERE shop_id='tofu';
```

多店舗認証は対象外。

## 商品バックアップと復元API

全APIで既存と同じ店舗限定のBearerトークンが必要。読み出しにも認証を要求し、Cache-Controlはno-store。

- `POST /v1/catalogs`: `schema_version:1, products:[{id,name,price}]`。最大1000商品・256KiB。IDでソートした商品JSONのSHA-256をスナップショットIDとし、同じ内容の再送は書込み0。空のバックアップも以前の行を削除しない。
- `GET /v1/catalogs?before=...`: `{schema_version:1,catalogs:[{id,product_count,received_at}],next}`。日時・IDの降順に20件ずつ。nextは不透明なカーソルとして次のbeforeへ渡す。
- `GET /v1/restore?catalog_id=...&after=...`: `{schema_version:1,catalog_id,after,products,orders,next}`。商品はafterが空の初回だけ。注文はshopの主キーでafterより後の50件を候補に、UTF-8 payload合計256KiBまで。単一の大きな会計も返して進行可能にする。nextがnullになるまでユーザー操作で続行する。

復元のSQLは次の50行だけを対象にウィンドウ集計し、HTTPに加えてD1の返却サイズも制限する。全履歴を毎回スキャンせず、復元要求でD1を書き込まない。商品は`cloud_catalogs`、会計は既存`cloud_orders`。migration 0002で商品テーブルと履歴用インデックスを追加し、既存売上は変更しない。

商品スナップショットを選んでも、売上はその時点の固定バックアップではなく、読み出し時のクラウドの最新状態。複数ページをまたぐ同時更新の一点時点整合性は保証しない。端末側の取消の単調性と内容照合で巻戻しを防ぐ。

## 0.4.0 API

文字数の上限（商品名・在庫メモ・取消理由・端末名・ID類）はすべてUnicodeコードポイント数で数える（Android・iOSと統一）。

すべて`schema_version:1`（追加フィールドのみ）。端末用APIは既存と同じBearer端末トークン、Cache-Controlはno-store。POSTは`application/json`・256KiBまで。形式不正は400、過大は413、D1障害は503＋Retry-After。

### migration 0003

`cloud_orders`に`seq`・`device_id`・`customer_age`・`customer_gender`・`created_at`を追加し、既存行は店舗ごとに主キー順で`seq`=1..Nを振り、他の列はpayloadからJSON1で埋める。既存明細は`json_each`で`cloud_order_lines`へ展開する。商品マスタ`cloud_products`、在庫イベント`cloud_stock_events`、レジセッション`cloud_sessions`を追加する。既存行は削除しない。仕様外の追加として、日付集計用`cloud_orders(shop_id,created_at)`とセッション一覧用`cloud_sessions(shop_id,opened_at)`のインデックスを作る。

### seq

注文・商品の作成/更新のたびに、書き込む文の中で店舗の`MAX(cloud_orders.seq, cloud_products.seq)+1`を振る（D1のbatchは直列なので一意）。注文の書き込みが勝つと、その明細を`cloud_order_lines`へ`INSERT OR REPLACE`し、明細に含まれる商品のseqも進める。どちらも「保存済みpayload_hashが自分のもの」という条件（EXISTSガード）付きで同じbatch内で行うため、並行した同一再送でも二重計上しない。

### POST /v1/sync（拡張）

注文に任意の`device_id`（1〜64文字）・`customer_age`（child/student/adult/senior）・`customer_gender`（male/female/other）・`customer_group`（solo/friends/family/couple/group）・`customer_relation`（acquaintance/relative/member/tofu_fan/general）・`ticket_no`（整理番号。8文字以内で`^(?:[A-Z]{1,2}-?)?[0-9]{1,4}$`、例`12`・`A-12`）。それぞれ`cloud_orders`の同名列にも保存する。null・未指定ならpayloadに含めないので、0.3.0の注文はpayloadとhashが変わらず、再送は従来どおり読み取りのみ。値はbase_hashにも入るので、同じrevisionで値が違えば競合。

### POST /v1/products

`{products:[{id,name,price,active,stop_at_zero?,image_hash?,track_stock?,base_version}]}`（最大100件）。`image_hash`（64桁小文字16進かnull）も内容比較とversionの対象で、省略はnull（写真なし）であり「変更なし」ではない。指定したhashの画像が`cloud_images`に無ければ、書き込まずに要求全体を400（`{error:"unknown image_hash",products:[id],image_hashes:[hash]}`）。端末は画像を先に送る。`stop_at_zero`（在庫0で販売を止める。省略時false）は内容比較とversionの対象。`track_stock`は受け付けるが無視し、応答では常に`true`（0.4.0初期ビルドとの互換）。名前は前後空白を除いて1〜100文字。行が無ければ`base_version`に関わらず作成し（version 1、`applied`。応答の`product`はnullにならない）、`base_version`が現行versionと一致すれば更新（version+1）。内容がサーバーと同じなら書き込まず`applied`。それ以外は`conflict`でサーバーを変えない。結果はbatch後の保存値で判定する。応答`{results:[{id,status,product}]}`。

### POST /v1/stock

`{events:[{id(UUID),product_id,kind:"add"|"set",quantity,reason?,created_at}]}`（最大100件）。addはquantity（±1,000,000）をそのまま、set（棚卸）は処理時点の在庫との差をdeltaとして記録する。同じidの再送は書き込まない。全商品が対象。商品が無い場合だけ`rejected`（`product_not_found`）。`stock_not_tracked`による拒否は廃止した。応答`{accepted,rejected,products}`。

在庫は保存せず、読み出し時に`SUM(delta) − SUM(取消でない明細の数量)`を集計する。全商品で計算し、フィード・products/stock応答・ダッシュボードの`stock`は常に整数（新規商品は0、販売超過で負数）。商品表現は`{id,name,price,active,track_stock:true,stop_at_zero,image_hash,version,stock,seq}`。

### POST /v1/sessions

`{sessions:[...]}`（最大20件）。`expected_total`は−1,000,000,000〜1,000,000,000の整数かnull。金種キーは`"10000"`〜`"1"`、枚数0〜9999。欠けた金種は0として正規化する。`float_total`・`counted_total`は金種×枚数と一致すること。idでupsertし、締め済み（closed_atあり）の行は以後変更しない。同内容の再送は書き込まず`accepted`。締め済みの行と内容が違う要求は`rejected:[{id,reason:"closed"}]`（仕様の応答に追加したフィールド）。

### GET /v1/feed?after=<seq>

`seq>after`の注文（最大100件・D1側でもpayload合計512KiBで打ち切り）と商品（最大1000件）をseq順にマージし、UTF-8で合計512KiBまで返す（最初の1件は必ず含む）。どちらかの一覧が上限で切れたときは、その最後のseqまでに留めて取りこぼしを防ぐ。応答`{after,next,has_more,products,orders}`。書き込みなし。

### ダッシュボード

- `GET /dashboard`: データを含まない静的HTML（外部読み込みなし、CSPで接続先を自オリジンに限定）。トークンは`sessionStorage`に置き、30秒ごと（タブが前面のとき）に再取得する。表示はJST。
- `GET /v1/dashboard?date=YYYY-MM-DD`: JSTの日付（省略で全期間）。合計・時間帯別・商品別・客層（年代×性別）・グループ別`groups:[{group,orders,sales}]`（未設定は`group:null`、solo→groupの順で未設定は最後）・関係別`relations:[{relation,orders,sales}]`（同様、acquaintance→generalの順）・在庫・端末別・最近の会計`recent:[{id,ticket_no,created_at,total,cancelled,device_id}]`（作成時刻の新しい順に20件）・レジ締めを返す。日付は注文の`created_at`、レジ締めは`opened_at`で絞る。在庫は全商品を少ない順に返し（`stop_at_zero`付き）、`stock`は常に全期間、`sold`は指定日の販売数。画面では負数の行を赤く強調し、`stop_at_zero`の商品が0以下なら「売り切れ」と付ける。

### 商品写真

保存先はD1（配備用トークンにR2権限が無いため）。端末が縮小してから送る。

- `POST /v1/images`: 端末トークンのみ。本文はJPEGそのもの（`Content-Type: image/jpeg`以外は415、512KiB超は413、先頭が`FF D8 FF`でなければ400）。サーバーでSHA-256（小文字16進）を計算し`INSERT OR IGNORE`。同じ内容の再送は読み取りのみ。応答`{schema_version:1,hash,size}`。
- `GET /v1/images/<hash>`: 端末トークンまたはダッシュボード用トークン（読み取りのみ）。`Content-Type: image/jpeg`、`Cache-Control: private, max-age=31536000, immutable`、`ETag: "<hash>"`、`If-None-Match`一致で304。無ければ404。
- BLOBはbind時に`Uint8Array`で渡す。D1は読み出し時に数値配列で返すため、`Uint8Array`へ変換して応答する。
- ダッシュボードの商品別・在庫の行に`image_hash`を含め、画面はダッシュボード用トークンで画像を取得してblob URLでサムネイルを出す（CSPは`img-src data: blob:`）。

migration 0005は`cloud_images(shop_id,hash,content_type,bytes,size,created_at)`と`cloud_products.image_hash`を追加する。

### migration 0004

`cloud_products`に`stop_at_zero INTEGER NOT NULL DEFAULT 0`を追加し、`track_stock`が1でない既存行を1にする。そうした行は今まで在庫がnullで配信されていたので、店舗の最大seqの後ろから新しいseqを振り、フィードで整数の在庫を届ける。`track_stock`列は互換のために残すが、Workerは参照しない。
