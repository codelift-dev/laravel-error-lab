# laravel-error-lab

Reproductions of Laravel runtime errors, run in Docker, with the output kept.

Each scenario starts from a clean application and changes **one variable at a
time**, so a result cannot be an artifact of somebody's local setup.

## `419 Page Expired`

Six different causes were reproduced. **All six produce a byte-identical
response** — same status, same page, nothing to tell them apart:

| Cause | HTTP |
|---|---|
| Form has no `@csrf` | 419 |
| Token malformed | 419 |
| Token valid, session cookie not sent | 419 |
| Token minted by a different session | 419 |
| `APP_KEY` rotated after the form was served | 419 |
| Session expired server-side | 419 |
| The same POST on an `api`-group route | **200** |

That is why "5 things to try" advice does not help: it lists fixes without any
way to find out which one applies to you.

So the second half builds a diagnostic that classifies the cause, and then
**replays all six scenarios to confirm the classification is correct** rather
than merely plausible. Two requirements turned out to be non-negotiable, and
both were discovered by getting them wrong first:

- the check must run **before `StartSession`** — by the time the exception
  handler sees the request, `EncryptCookies` has nulled the undecryptable
  cookie and `StartSession` has already minted a replacement session, which
  collapses "rotated key" and "expired session" into "token mismatch"
- the render callback **cannot be typed on `TokenMismatchException`** — it
  never fires, because `prepareException()` rewrites it to `HttpException(419)`
  before the callbacks are consulted

Copy `work/CsrfDiagnosis.php` and `work/DiagnoseCsrf.php` into an application
as-is; `work/install-diagnosis.php` shows the registration.

Full write-up: <https://codelift.lb-product.com/en/articles/laravel-419-page-expired-diagnosis>

## `Vite manifest not found`

Six cases, and the advice everyone gives — "run `npm run build`" — is the answer
to exactly one of them. Two of the six **return HTTP 200 and throw nothing**:

| Cause | HTTP | Exception |
|---|---|---|
| `public/build` deleted | 500 | `ViteManifestNotFoundException` |
| **`public/hot` left behind** | **200** | **none** |
| `public/hot` left behind, no build | **200** | **none** |
| manifest only at `public/build/.vite/` | 500 | `ViteManifestNotFoundException` — *identical message* |
| `@vite()` names a missing entry | 500 | `ViteException` |

The hot-file case is the one that costs a day: the page renders, the status is
200, the logs stay empty, and the browser is quietly told to fetch assets from
a dev server that is not running. **`npm run build` does not remove
`public/hot`** — measured, not assumed — so the standard advice cannot fix it.

Full write-up: <https://codelift.lb-product.com/en/articles/laravel-vite-manifest-not-found>

## `Target class [X] does not exist.`

Thirteen cases. **`composer dump-autoload` changes the outcome of exactly one
of them**, and the case it fixes only exists if you ran
`--classmap-authoritative` first:

| Cause | HTTP | What is actually logged |
|---|---|---|
| `'ProbeController@index'` — bare name | 500 | `Target class [ProbeController] does not exist.` |
| `'App\Http\Controllers\ProbeController@index'` | **200** | the string form still works, fully qualified |
| `namespace` inside the file is wrong | 500 | **`Cannot redeclare class ...`** — a different error |
| file name vs class name differ in case | 500 | `Target class ... does not exist.` — **Linux only** |
| new file, autoloader never regenerated | **200** | nothing; the regeneration is not needed |
| new file after `--classmap-authoritative` | 500 | `Target class ... does not exist.` |
| constructor needs an unbound interface | 500 | **`Target [...] is not instantiable`** — different again |
| `route:cache` predates a controller rename | 500 | `Target class [the old name] does not exist.` |

The last one is the one that reaches production. `route:cache` bakes the
controller's fully-qualified name into `bootstrap/cache/routes-v7.php`, so
after a rename **the message names a class that exists nowhere in the code**.
`composer dump-autoload` does not fix it — measured, not assumed.
`php artisan route:clear` does.

Two environment traps had to be removed before any of this could be measured,
and both silently produced wrong answers first: a host bind mount is
case-insensitive even inside a Linux container, which neutralised the
case-mismatch cause entirely, and with `APP_DEBUG=true` the PHP built-in
server drops the connection instead of rendering the error page. Both are
written up in [VERIFICATION.md](VERIFICATION.md).

Full write-up: <https://codelift.lb-product.com/en/articles/laravel-target-class-does-not-exist>

## Run it

```bash
docker compose build
docker compose run --rm lab bash 419-page-expired.sh      # reproduce every 419 cause
docker compose run --rm lab bash 419-diagnose.sh          # classify every 419 cause
docker compose run --rm lab bash vite-manifest.sh         # reproduce every Vite case
docker compose run --rm lab bash vite-manifest-detail.sh  # exact exception text
docker compose run --rm lab bash target-class.sh          # reproduce every Target class case
```

Nothing is installed on the host. The server and the client both run inside
the container, so there are no port collisions and no host PHP involved.

Verified against Laravel **13.21.1** / PHP 8.4.23 (419), Laravel **13.23.0** /
PHP 8.4.24 / Node 22.23.2 (Vite), and Laravel **13.30.1** / PHP 8.4.25 /
Composer 2.10.3 (Target class). Details, and the harness bug that briefly
produced two wrong conclusions: [VERIFICATION.md](VERIFICATION.md).

---

Part of [CodeLift](https://codelift.lb-product.com) — we verify official sample
code in Docker and publish what actually happens.
