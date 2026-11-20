# アプリアイコンの素材

「Are you Tofu?」の「Tofu」の `o` に使われている豆腐の図形を使用。

- ベクター元: Google Drive / Are you Tofu?_ver.2 / KV / [areyoutofu2026.ai](https://drive.google.com/file/d/1a7UNPHY2PaGsqcP56X5-FS2Xxcsq2kFH/view)
- 色の参照: 同じフォルダーの [AyT2_KV_fin.png](https://drive.google.com/file/d/1DS1PlNJJ4Bbc3W5BqruJ015trvxdqriH/view)。白 `#FFFFFF`、右面 `#FFE8A9`。
- `tofu-mark.svg`: 元Illustratorの曲線とクリップを保持し、位置とサイズだけを正規化した透過ベクター。背景は含まない。
- Android: 緑 `#006B57` の背景と分けたadaptive icon。108dpレイヤー内で豆腐の高さを64dpにし、円形などのシステムマスクで切れないように配置。Android 13以降のテーマアイコンは元図形のシルエットを使用。
- iOS: 同じ緑背景と比率で1024pxの不透明PNGを `ios/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` に書き出し。角丸はOSが付ける。

元のポスター全体や写真はアプリへ同梱しない。Androidリソースは `android/app/src/main/res/drawable/ic_tofu_*.xml` と `mipmap-anydpi*/ic_launcher.xml`。
