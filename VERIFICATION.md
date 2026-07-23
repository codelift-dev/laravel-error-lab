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
