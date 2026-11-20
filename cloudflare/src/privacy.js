// Public privacy policy for the store listing (Google Play / App Store). Static, no data.
export const PRIVACY_HTML = `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TOS プライバシーポリシー</title>
<style>
:root{--bg:#F8F7F6;--fg:#2E2018;--muted:#635954;--accent:#B66427}
@media (prefers-color-scheme:dark){:root{--bg:#2E2018;--fg:#F6F4F3;--muted:#ADA29C;--accent:#D18C53}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.75 system-ui,-apple-system,"Hiragino Sans","Noto Sans JP",sans-serif}
main{max-width:720px;margin:0 auto;padding:32px 16px 64px}h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:2em}a{color:var(--accent)}
</style>
</head>
<body><main>
<h1>TOS プライバシーポリシー</h1>
<p>施行日：2026年11月21日</p>

<h2>1. このアプリについて</h2>
<p>「TOS」は、東京大学の駒場祭で出店する豆腐田楽のお店（Are you Tofu?）のスタッフ専用レジアプリです。一般のお客さん向けではなく、クローズドテストで店のスタッフだけに配布しています。</p>

<h2>2. 送信するデータと送信先</h2>
<p>本アプリは、店が運営するCloudflare上のサーバー（Workers・D1）へ以下のデータを送信します。通信できない場合でも会計は端末に保存され、通信がつながったときに自動で送信します。</p>
<ul>
  <li>会計内容（商品、数量、金額、時刻、整理番号、客層の区分、取消）</li>
  <li>商品、在庫、レジ締めの記録</li>
  <li>商品写真</li>
  <li>端末ごとのランダムな識別子および端末の機種名</li>
</ul>
<p>写真は利用者が選んだ商品写真のみを対象とし、端末で縮小して位置情報などのメタデータを除いてから送信します。</p>

<h2>3. 収集しない情報</h2>
<p>氏名、メールアドレス、電話番号、位置情報、連絡先などの個人情報は収集しません。</p>

<h2>4. データの利用目的</h2>
<p>データは店の売上管理のためだけに利用します。</p>

<h2>5. 第三者提供・広告・分析ツールについて</h2>
<p>データの第三者への提供および販売は行いません。また、広告、分析ツール、トラッキングは使用していません。</p>

<h2>6. お問い合わせ</h2>
<p>本アプリに関するお問い合わせは、以下のメールアドレスまでご連絡ください。</p>
<p>__CONTACT__</p>
</main></body>
</html>`;
