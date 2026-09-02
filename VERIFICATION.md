# Laravel `419 Page Expired` 検証記録

実施日: 2026-07-23
実行環境: Docker Desktop / `php:8.4-cli-bookworm` / Laravel 13.21.1
サーバと curl は同一コンテナ内。ホスト環境の影響を受けない。

---

## Phase 1 — 原因を 1 変数ずつ再現する

正常系から**一度に 1 つだけ**条件を変えて計測した。

| ケース | 変更点 | HTTP |
|---|---|---|
| A | （正常系） | **200** |
| B | `_token` を送らない | 419 |
| C | `_token` を壊れた値にする | 419 |
| D | `_token` は正しいが Cookie を送らない | 419 |
| E | 別セッションが発行したトークンを使う | 419 |
| F | フォーム表示後に `APP_KEY` をローテート | 419 |
| G | セッションをサーバ側で期限切れにする | 419 |
| H | 同じ POST を `api` グループのルートへ | **200** |

### 最重要の観察

**B〜G はすべて、外から見て完全に同一の応答である。** ステータスも本文も
`419 / Page Expired` で、区別する材料が 1 つも無い。

世に出回っている「419 の対処法 5 選」が機能しないのはこれが理由である。
対処法は列挙できても、**自分がどれに該当するか判定する手段が無い**。

H が 200 なのは、`api` グループに CSRF 検証が入っていないため。
419 が出るかどうかはルートが属するミドルウェアグループで決まる。

### 検証中に踏んだ落とし穴（結論を汚染していた）

最初の実行では **F と G が 200** になり、「`APP_KEY` を変えても 419 にならない」
という結論が出かけた。原因はテスト側にあった。

`php artisan serve` は PHP ビルトインサーバを**子プロセス**として起動する。
親だけ kill すると子がポート 8000 を掴んだまま残り、次の起動確認 curl が
**古いサーバに応答**する。以降の設定変更は一切反映されない。

対策として、プロセス一族を kill してポートが閉じるまで待つようにし、さらに
`/_probe` エンドポイントで**実行中サーバが読んでいる設定値と PID** を毎回
出力させた。pid が 100 → 304 に変わり `lifetime=1` が反映されたことを確認して
初めて F・G の結果を採用している。

---

## Phase 2 — 6 つの原因を区別する

外から区別できない以上、サーバ側で判定するしかない。判定器を実装し、
**Phase 1 と同じシナリオを再生して分類が正しいか検証**した。

| ケース | 期待する分類 | 実測 |
|---|---|---|
| B | `NO_TOKEN_SUBMITTED` | ✅ |
| D | `NO_SESSION_COOKIE` | ✅ |
| E | `TOKEN_MISMATCH` | ✅ |
| F | `COOKIE_UNDECRYPTABLE` | ✅ |
| G | `SESSION_GONE` | ✅ |
| A | 正常系は 200 のまま | ✅ |

### 設計上、外せない条件が 2 つある

どちらも最初の実装で踏み、**F と G が誤判定（両方 `TOKEN_MISMATCH`）になった**。

**1. 判定は `StartSession` より前で行う必要がある**

例外ハンドラの時点では、区別に必要な証拠が 2 つとも失われている。

- `EncryptCookies` は復号に失敗した Cookie を**削除せず null にセット**する。
  そのため `$request->cookies->has()` は true のままで、`APP_KEY` ローテートが
  正常なリクエストと同じに見える
- `StartSession` は既に**新しいセッションを作り終えている**。新品のトークンを
  持っているので、期限切れセッションが「生きているが別トークン」と区別できない

よってミドルウェアを **`prepend`** で web グループの先頭に置く。後ろに置くと
すべてが `TOKEN_MISMATCH` になり、置き換えたかった役に立たない答えに戻る。

**2. render コールバックを `TokenMismatchException` 型で登録してはいけない**

一番自然に書く形だが、**構造上絶対に発火しない**。フレームワークのソースが根拠:

```
Handler.php:710   $e = $this->prepareException($e);
Handler.php:768   $e instanceof TokenMismatchException => new HttpException(419, $e->getMessage(), $e)
Handler.php:712   $this->renderViaCallbacks($request, $e)
```

`prepareException()` が `HttpException(419)` に**書き換えた後**でコールバックが
参照される。元の例外は第 3 引数で `previous` として保持されるので、そこを見る。

```php
$exceptions->render(function (HttpException $e, Request $request) {
    if ($e->getStatusCode() !== 419
        || ! $e->getPrevious() instanceof TokenMismatchException) {
        return null;
    }
    // ...
});
```

ステータスコードだけで判定しないのは、419 は他の理由でも返しうるため。

---

## 再現

```bash
docker compose build
docker compose run --rm lab bash 419-page-expired.sh   # Phase 1
docker compose run --rm lab bash 419-diagnose.sh       # Phase 2
```


---

# Laravel `Vite manifest not found` 検証記録

実施日: 2026-08-02
実行環境: Docker Desktop / `php:8.4-cli-bookworm` + Node 22.23.2
Laravel 13.23.0 / PHP 8.4.24

**実際に `npm run build` を走らせている。** manifest.json を手書きして
それらしく見せることはしていない。

## 結果一覧

| ケース | 変更点 | HTTP | 例外 |
|---|---|---|---|
| A | （正常系） | 200 | — |
| B | `public/build` ごと削除 | 500 | `ViteManifestNotFoundException` |
| C | **`public/hot` が残っている**（build はある） | **200** | **なし** |
| D | `public/hot` が残っていて build も無い | **200** | **なし** |
| E | manifest が `public/build/.vite/` にだけある | 500 | `ViteManifestNotFoundException` |
| F | `@vite()` が manifest に無いエントリを参照 | 500 | `ViteException` |

## 1. 例外は 2 種類ある

同じ「manifest 関連」でも、投げられるクラスもメッセージも違う。

**B / E:**
```
Illuminate\Foundation\ViteManifestNotFoundException
Vite manifest not found at: /lab/vite-app/public/build/manifest.json
```

**F:**
```
Illuminate\Foundation\ViteException
Unable to locate file in Vite manifest: resources/js/does-not-exist.js.
```

F は「manifest は読めたが、その中に指定のエントリが無い」。B/E とは対処が違う。

## 2. B と E はメッセージが完全に同一

E は manifest ファイル自体は存在する（`public/build/.vite/manifest.json`）。
だが Laravel が見るのは `public/build/manifest.json` 固定なので、
**「ファイルが無い」と全く同じエラーになる**。

根拠（`Illuminate/Foundation/Vite.php`）:

```
56:  protected $manifestFilename = 'manifest.json';
975: protected function manifestPath($buildDirectory)
977:     return public_path($buildDirectory.'/'.$this->manifestFilename);
```

`laravel-vite-plugin` は manifest を `public/build/manifest.json` に配置する。
素の Vite 設定で組んだ場合や、プラグインを外した場合に `.vite/` の下だけに
出力されると、この状態になる。

## 3. 最も厄介なのは C — エラーが出ない

`public/hot` が残っていると、**HTTP 200 でページが返り、例外は一切出ない**。

```
served:
  <script type="module" src="http://127.0.0.1:5173/@vite/client">
  <link rel="stylesheet" href="http://127.0.0.1:5173/resources/css/app.css" />
  <script type="module" src="http://127.0.0.1:5173/resources/js/app.js">
```

ブラウザはこの URL を取りに行くが:

```
http://127.0.0.1:5173/@vite/client -> connection refused (nothing is listening)
```

サーバのログには何も残らず、ステータスも 200。**画面だけが無スタイルで壊れる。**

根拠:

```
239:  return $this->hotFile ?? public_path('/hot');
1223: return is_file($this->hotFile());
```

`isRunningHot()` が true の場合、**manifest は一切読まれない**。だから D
（hot あり + build 無し）でも 200 が返る。

### `npm run build` はこれを直せない

実測した。

```
after 'npm run build' with a hot file present: STILL THERE
```

**ビルドは `public/hot` を削除しない。** 「manifest が無いと言われたら
`npm run build`」という定番の助言は、このケースに対して無効である。
`rm public/hot` が要る。

## 再現

```bash
docker compose build
docker compose run --rm lab bash vite-manifest.sh          # 6 ケースの再現
docker compose run --rm lab bash vite-manifest-detail.sh   # 例外の正確な文言
```

---

# Laravel `Target class [X] does not exist.` 検証記録

実施日: 2026-09-02
実行環境: Docker Desktop / `php:8.4-cli-bookworm` / Laravel 13.30.1 / PHP 8.4.25 / Composer 2.10.3
**アプリはコンテナ内 `/build` に作る**（理由は「環境が結論を消していた」を参照）

## 結果一覧

| ケース | 条件 | HTTP | ログに出た例外 |
|---|---|---|---|
| A | `[Class::class, 'method']`（正常系） | **200** | — |
| B | `'ProbeController@index'`（名前空間なし文字列） | 500 | `Target class [ProbeController] does not exist.` |
| C | `'App\Http\Controllers\ProbeController@index'` | **200** | — |
| D | ファイルの `namespace` がディレクトリと不一致 | 500 | **`Cannot redeclare class ...`**（`FatalError`） |
| E | ファイル名とクラス名が大文字小文字だけ違う | 500 | `Target class [...] does not exist.` |
| F | 新規ファイル。`composer dump-autoload` 未実行 | **200** | — |
| G | `--classmap-authoritative` の後に新規ファイル追加 | 500 | `Target class [...] does not exist.` |
| H | G の状態で `composer dump-autoload` | **200** | — |
| I | コンストラクタが未バインドの interface を要求 | 500 | **`Target [...] is not instantiable while building [...]`** |
| J | コンストラクタが存在しないクラスを要求 | 500 | `Target class [...] does not exist.` |
| K | `route:cache` 後にコントローラをリネーム | 500 | `Target class [旧名] does not exist.` |
| L | K の状態で `composer dump-autoload` | **500（変わらず）** | 同上 |
| M | K の状態で `php artisan route:clear` | **200** | — |

## 観察

**1. `composer dump-autoload` が効くのは G だけ。**
F が 200 である以上、新しいクラスファイルを置いただけなら再生成は要らない。
G は `--classmap-authoritative`（本番デプロイの定番オプション）を打った後に
ファイルを足した場合で、このときだけ再生成が必要になる。

**2. K・L・M が実務で一番刺さる。**
`route:cache` はコントローラの FQCN を `bootstrap/cache/routes-v7.php` に焼き込む。
リネーム後もキャッシュが古い名前を持ち続けるので、**エラーメッセージはコードの
どこにも存在しないクラス名を指す**。`composer dump-autoload` では直らない（L）。
`route:clear` で直る（M）。

**3. 名前空間の書き間違いは、この例外を出さない。**
D は `Cannot redeclare class` という別物の致命的エラーになる。ログに出たのは
この 1 件のみ（他のメッセージは無し）。PSR-4 が正しいパスのファイルを読み、
そこに別のクラスが宣言されていて、目的のクラスは見つからないまま同じファイルが
もう一度 include されるため。

**4. `is not instantiable` は別の話。**
I は interface が存在しないのではなく、**バインドが無い**。文字列も違う。
この 2 つを混同したまま「Target class」で検索すると解決しない。

**5. 文字列でのアクション指定は死んでいない。**
C が 200。壊れるのは B（名前空間を省いた形）だけで、完全修飾すれば動く。
Laravel 11 で `RouteServiceProvider` が消えたので `$namespace` を書き戻す
場所自体が無く、「コメントアウトを外す」という定番の助言は実行不可能。

## 環境が結論を消していた

最初の実行はアプリを `/lab`（ホストからの bind mount）に作っていた。
**Windows / macOS ホストの bind mount は、コンテナが Linux でも大文字小文字を
区別しない。** その結果 E が 200 になり、

```
class_exists("App\Http\Controllers\ProbeController")  => true
ReflectionClass::getFileName()  => .../ProbeController.php   ← 存在しないファイル
```

という状態になっていた。実在するのは `Probecontroller.php` だけである。
**この scenario の目玉である「Linux でだけ落ちる原因」を、環境そのものが
無効化していた。** アプリをコンテナ内 `/build` に移して再取得した。

## もう 1 つの落とし穴 — `APP_DEBUG=true` だと計測できない

失敗ケースが全て `HTTP 000` になり、アクセスログにも残らず、以降のリクエストも
全滅した。アプリが落ちているように見えるが、実際は **PHP ビルトインサーバ
（`artisan serve` でも素の `php -S` でも）がデバッグ画面の描画中に接続を切っている**。
`APP_DEBUG=false` にすると同じケースが素直に 500 を返す。
本番はそもそも `APP_DEBUG=false` なので、記録した値は本番の挙動でもある。

## 再現

```bash
docker compose build
docker compose run --rm lab bash target-class.sh
```

