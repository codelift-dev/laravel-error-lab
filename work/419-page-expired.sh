#!/usr/bin/env bash
# Reproduce every documented cause of Laravel's "419 Page Expired", one
# variable at a time, against a clean application.
#
# The point is not to show that 419 happens — everyone knows that. It is to
# find out which causes are DISTINGUISHABLE from the outside, because the
# advice online is a list of fixes with no way to tell which one applies.
#
# Server and client run in the same container. Each case starts from a fresh
# cookie jar so state cannot leak between them.
set -uo pipefail

APP=/lab/app419
BASE=http://127.0.0.1:8000

# ---------------------------------------------------------------- build ----
if [ ! -d "$APP" ]; then
  cd /lab
  echo "=== creating the application ==="
  composer create-project laravel/laravel app419 --no-interaction --quiet
fi

cd "$APP"
php artisan --version

cat > routes/web.php <<'PHP'
<?php

use Illuminate\Support\Facades\Route;

Route::get('/form', function () {
    return response(
        '<form method="POST" action="/form">'
        .csrf_field()
        .'<input name="payload" value="x"><button>go</button></form>'
    );
});

Route::post('/form', fn () => response('ACCEPTED', 200));

// Lets each case PROVE the running server picked up the config it was
// restarted for, instead of assuming the restart worked.
Route::get('/_probe', fn () => response(sprintf(
    "key=%s lifetime=%s pid=%d\n",
    substr(md5((string) config('app.key')), 0, 8),
    config('session.lifetime'),
    getmypid(),
)));
PHP

# An api-guarded twin, to show what the middleware group actually controls.
cat > routes/api.php <<'PHP'
<?php

use Illuminate\Support\Facades\Route;

Route::post('/form', fn () => response('ACCEPTED', 200));
PHP

# 'install:api' is not dependable here: it no-ops when routes/api.php already
# exists, leaving withRouting() without an api: entry, and the route then 404s
# instead of demonstrating anything about CSRF. Register it explicitly so case
# H measures the middleware group and not the routing setup.
php -r '
$p = "bootstrap/app.php";
$s = file_get_contents($p);
if (!str_contains($s, "api: __DIR__")) {
    $s = str_replace(
        "web: __DIR__.\"/../routes/web.php\",",
        "web: __DIR__.\"/../routes/web.php\",\n        api: __DIR__.\"/../routes/api.php\",",
        str_replace("'\''", "\"", $s)
    );
    file_put_contents($p, $s);
    echo "registered api routes\n";
} else {
    echo "api routes already registered\n";
}
'
grep -n "api:" bootstrap/app.php || echo "  !! api: still not registered"

sed -i 's/^SESSION_DRIVER=.*/SESSION_DRIVER=file/' .env
grep -q '^SESSION_LIFETIME=' .env || echo 'SESSION_LIFETIME=120' >> .env
touch database/database.sqlite
php artisan migrate --force --quiet >/dev/null 2>&1

start_server() {
  php artisan config:clear >/dev/null 2>&1
  php artisan route:clear >/dev/null 2>&1
  php artisan serve --host=127.0.0.1 --port=8000 >/tmp/serve.log 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "$BASE/form" && return 0
    sleep 0.25
  done
  echo "server failed to start"; cat /tmp/serve.log; exit 1
}

probe() {
  printf '    [server] %s' "$(curl -s "$BASE/_probe")"
}

stop_server() {
  # 'artisan serve' spawns the PHP built-in server as a CHILD. Killing only the
  # parent leaves that child holding port 8000, so the next start_server's
  # readiness curl succeeds against the OLD process and every subsequent
  # config change silently has no effect. Kill the whole family and then wait
  # for the port to actually go away.
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  pkill -f 'artisan serve' 2>/dev/null
  pkill -f 'php -S 127.0.0.1:8000' 2>/dev/null
  for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 1 "$BASE/form" || return 0
    sleep 0.25
  done
  echo "  !! port 8000 still answering after stop_server"
  SERVER_PID=""
}

# Fetch the form, keep its cookies, and post back the token it handed us.
# Any argument overrides are applied to the POST only.
get_token() {
  local jar=$1
  rm -f "$jar"
  curl -s -c "$jar" "$BASE/form" | grep -o 'name="_token" value="[^"]*"' | sed 's/.*value="//;s/"//'
}

post_status() {
  local jar=$1 token=$2 path=${3:-/form}
  curl -s -o /tmp/body.txt -w '%{http_code}' -b "$jar" -c "$jar" \
    -X POST "$BASE$path" -d "_token=$token" -d "payload=x"
}

report() {
  printf '  %-46s -> HTTP %s\n' "$1" "$2"
}

echo
echo "############################################################"
echo "# each case changes exactly one thing from the working case #"
echo "############################################################"
start_server
probe

echo
echo "=== A. baseline: valid token, same session ==="
T=$(get_token /tmp/jarA.txt)
report "correct token" "$(post_status /tmp/jarA.txt "$T")"
echo "     token prefix: ${T:0:12}..."

echo
echo "=== B. no token at all ==="
rm -f /tmp/jarB.txt
curl -s -c /tmp/jarB.txt -o /dev/null "$BASE/form"
report "_token omitted" "$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/jarB.txt -X POST "$BASE/form" -d 'payload=x')"

echo
echo "=== C. malformed token ==="
T=$(get_token /tmp/jarC.txt)
report "_token replaced with garbage" "$(post_status /tmp/jarC.txt 'not-a-real-token')"

echo
echo "=== D. valid token, but the session cookie is dropped ==="
T=$(get_token /tmp/jarD.txt)
report "token kept, cookie jar discarded" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/form" -d "_token=$T" -d 'payload=x')"

echo
echo "=== E. token minted by a DIFFERENT session ==="
T1=$(get_token /tmp/jarE1.txt)
T2=$(get_token /tmp/jarE2.txt)
report "session 2's cookie + session 1's token" "$(post_status /tmp/jarE2.txt "$T1")"

echo
echo "=== F. APP_KEY rotated between GET and POST ==="
echo "    (this is what a deploy that regenerates the key does to live users)"
T=$(get_token /tmp/jarF.txt)
stop_server
OLD_KEY=$(grep '^APP_KEY=' .env)
php artisan key:generate --force --quiet
echo "    key changed: $(grep '^APP_KEY=' .env | cut -c1-24)..."
start_server
report "token from before the key rotation" "$(post_status /tmp/jarF.txt "$T")"
stop_server
sed -i "s|^APP_KEY=.*|$OLD_KEY|" .env
start_server

echo
echo "=== G. session already expired when the form is posted ==="
stop_server
sed -i 's/^SESSION_LIFETIME=.*/SESSION_LIFETIME=1/' .env
start_server
probe
T=$(get_token /tmp/jarG.txt)
report "posted immediately (lifetime=1min)" "$(post_status /tmp/jarG.txt "$T")"
echo "    ageing the session file past its lifetime..."
find storage/framework/sessions -type f -exec touch -d '10 minutes ago' {} \;
T2=$(get_token /tmp/jarG2.txt)
find storage/framework/sessions -type f -exec touch -d '10 minutes ago' {} \;
report "posted after the session aged out" "$(post_status /tmp/jarG2.txt "$T2")"
stop_server
sed -i 's/^SESSION_LIFETIME=.*/SESSION_LIFETIME=120/' .env
start_server

echo
echo "=== H. the same POST on an api-group route ==="
report "POST /api/form, no token, no cookie" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/form" -d 'payload=x')"

echo
echo "=== I. what does the 419 body actually say? ==="
rm -f /tmp/jarI.txt
curl -s -c /tmp/jarI.txt -o /dev/null "$BASE/form"
curl -s -b /tmp/jarI.txt -X POST "$BASE/form" -d 'payload=x' \
  | grep -oE '(Page Expired|CSRF token mismatch|419)' | sort -u | sed 's/^/     /'

stop_server
echo
echo "=== done ==="
