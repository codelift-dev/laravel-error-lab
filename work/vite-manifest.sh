#!/usr/bin/env bash
# Reproduce the ways a Laravel app fails to find its Vite manifest.
#
# The question is not "does it fail" — it obviously does. It is which failures
# actually produce "Vite manifest not found", which produce something else
# entirely, and whether the message tells you which one you have. The advice
# online is almost uniformly "run npm run build", which is right for exactly
# one of these cases.
#
# The real build runs. Nothing here hand-writes a manifest.json.
set -uo pipefail

APP=/lab/vite-app
BASE=http://127.0.0.1:8000

if [ ! -d "$APP" ]; then
  cd /lab
  echo "=== creating the application ==="
  composer create-project laravel/laravel vite-app --no-interaction --quiet
  cd "$APP"
  echo "=== npm install ==="
  npm install --no-audit --no-fund --silent
fi

cd "$APP"
php artisan --version
node --version | sed 's/^/  node /'

# A page that renders @vite, so a manifest problem surfaces as a page failure
# rather than staying invisible.
cat > routes/web.php <<'PHP'
<?php

use Illuminate\Support\Facades\Route;

Route::get('/probe', fn () => view('probe'));
PHP

mkdir -p resources/views
cat > resources/views/probe.blade.php <<'BLADE'
<!doctype html>
<html>
<head>@vite(['resources/css/app.css', 'resources/js/app.js'])</head>
<body>PROBE OK</body>
</html>
BLADE

start_server() {
  php artisan config:clear >/dev/null 2>&1
  php artisan view:clear >/dev/null 2>&1
  php artisan serve --host=127.0.0.1 --port=8000 >/tmp/serve.log 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "$BASE/probe" && return 0
    sleep 0.25
  done
  echo "server failed to start"; cat /tmp/serve.log; exit 1
}

stop_server() {
  # artisan serve spawns the built-in server as a child; killing only the
  # parent leaves it holding the port and every later case measures the old
  # process. Cost two false findings in the 419 work — see VERIFICATION.md.
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  pkill -f 'artisan serve' 2>/dev/null
  pkill -f 'php -S 127.0.0.1:8000' 2>/dev/null
  for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 1 "$BASE/probe" || return 0
    sleep 0.25
  done
  echo "  !! port 8000 still answering"
}

# Report the status plus the first meaningful line of the failure, so cases
# that fail differently are visibly different.
probe() {
  local label=$1
  local code body first
  code=$(curl -s -o /tmp/body.html -w '%{http_code}' "$BASE/probe")
  body=$(cat /tmp/body.html)
  if echo "$body" | grep -q 'PROBE OK'; then
    first="renders — $(echo "$body" | grep -oE '/build/assets/[^"]+' | head -2 | tr '\n' ' ')"
    first="${first}$(echo "$body" | grep -oE 'http://\[?[^"]*:5173[^"]*' | head -1)"
  else
    first=$(echo "$body" | grep -oE 'Vite manifest not found at: [^<]*|Unable to locate file in Vite manifest: [^<]*|[A-Za-z\\]*Exception[^<]{0,80}' | head -1)
    [ -z "$first" ] && first=$(echo "$body" | sed 's/<[^>]*>//g' | tr -s ' \n' ' ' | cut -c1-100)
  fi
  printf '  %-46s HTTP %-4s %s\n' "$label" "$code" "$first"
}

echo
echo "=================================================================="
echo " each case changes one thing about what is on disk"
echo "=================================================================="

echo
echo "=== A. baseline: npm run build has been run ==="
npm run build >/tmp/build.log 2>&1 || { echo "build failed"; tail -20 /tmp/build.log; exit 1; }
echo "  manifest on disk:"
find public/build -name '*.json' | sed 's/^/    /'
start_server; probe "built, manifest present"; stop_server

echo
echo "=== B. no build at all (fresh clone, deploy forgot npm run build) ==="
mv public/build /tmp/build-backup
start_server; probe "public/build removed"; stop_server
mv /tmp/build-backup public/build

echo
echo "=== C. public/hot left behind by an interrupted 'npm run dev' ==="
echo "    (build IS present — this is the case where npm run build does not help)"
printf 'http://127.0.0.1:5173' > public/hot
start_server; probe "hot file present, dev server NOT running"; stop_server
rm -f public/hot

echo
echo "=== D. hot file present AND no build ==="
printf 'http://127.0.0.1:5173' > public/hot
mv public/build /tmp/build-backup
start_server; probe "hot present, build absent"; stop_server
mv /tmp/build-backup public/build
rm -f public/hot

echo
echo "=== E. build present but manifest only under .vite/ (raw vite output) ==="
if [ -f public/build/manifest.json ]; then
  mkdir -p public/build/.vite
  cp public/build/manifest.json public/build/.vite/manifest.json
  mv public/build/manifest.json /tmp/manifest-backup.json
  start_server; probe "manifest at .vite/manifest.json only"; stop_server
  mv /tmp/manifest-backup.json public/build/manifest.json
  rm -rf public/build/.vite
else
  echo "  (skipped: manifest.json was not at public/build/manifest.json)"
fi

echo
echo "=== F. manifest present but the entry name does not match ==="
cat > resources/views/probe.blade.php <<'BLADE'
<!doctype html>
<html>
<head>@vite(['resources/js/does-not-exist.js'])</head>
<body>PROBE OK</body>
</html>
BLADE
start_server; probe "@vite references a missing entry"; stop_server
cat > resources/views/probe.blade.php <<'BLADE'
<!doctype html>
<html>
<head>@vite(['resources/css/app.css', 'resources/js/app.js'])</head>
<body>PROBE OK</body>
</html>
BLADE

echo
echo "=== G. what the manifest actually contains ==="
php -r '
$m = json_decode(file_get_contents("public/build/manifest.json"), true);
foreach ($m as $k => $v) {
    printf("  %-34s -> %s\n", $k, $v["file"]);
}'

echo
echo "=== done ==="
