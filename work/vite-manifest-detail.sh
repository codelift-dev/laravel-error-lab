#!/usr/bin/env bash
# Second pass: capture the exact exception class and message per case, and
# establish what the browser is actually served in the case that returns 200.
#
# The headline from pass one is that a leftover public/hot produces no error
# at all — so the failure has to be characterised by what reaches the browser,
# not by an exception.
set -uo pipefail

APP=/lab/vite-app
BASE=http://127.0.0.1:8000
cd "$APP"

start_server() {
  php artisan config:clear >/dev/null 2>&1
  php artisan view:clear >/dev/null 2>&1
  php artisan serve --host=127.0.0.1 --port=8000 >/tmp/serve.log 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 40); do curl -s -o /dev/null "$BASE/probe" && return 0; sleep 0.25; done
  echo "server failed"; cat /tmp/serve.log; exit 1
}
stop_server() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  pkill -f 'artisan serve' 2>/dev/null
  pkill -f 'php -S 127.0.0.1:8000' 2>/dev/null
  for _ in $(seq 1 40); do curl -s -o /dev/null --max-time 1 "$BASE/probe" || return 0; sleep 0.25; done
  echo "  !! port still answering"
}

# Exact exception class + message, straight out of the JSON error response.
detail() {
  local label=$1
  local code
  code=$(curl -s -H 'Accept: application/json' -o /tmp/err.json -w '%{http_code}' "$BASE/probe")
  echo "--- $label  (HTTP $code)"
  if [ "$code" = "200" ]; then
    echo "    exception : none — the page rendered"
    echo "    served    :"
    curl -s "$BASE/probe" | grep -oE '<(script|link)[^>]*>' | sed 's/^/      /'
  else
    php -r '
      $j = json_decode(file_get_contents("/tmp/err.json"), true);
      printf("    exception : %s\n", $j["exception"] ?? "(none)");
      printf("    message   : %s\n", $j["message"] ?? "(none)");
    '
  fi
  echo
}

echo "=================================================================="
echo " exact exception per case"
echo "=================================================================="
echo

start_server; detail "A. built, manifest present"; stop_server

mv public/build /tmp/bk
start_server; detail "B. public/build removed"; stop_server
mv /tmp/bk public/build

printf 'http://127.0.0.1:5173' > public/hot
start_server; detail "C. public/hot present, build present, dev server down"; stop_server
rm -f public/hot

mkdir -p public/build/.vite
cp public/build/manifest.json public/build/.vite/manifest.json
mv public/build/manifest.json /tmp/mf.json
start_server; detail "E. manifest only at public/build/.vite/manifest.json"; stop_server
mv /tmp/mf.json public/build/manifest.json
rm -rf public/build/.vite

cat > resources/views/probe.blade.php <<'BLADE'
<!doctype html>
<html><head>@vite(['resources/js/does-not-exist.js'])</head><body>PROBE OK</body></html>
BLADE
start_server; detail "F. @vite entry not in the manifest"; stop_server
cat > resources/views/probe.blade.php <<'BLADE'
<!doctype html>
<html><head>@vite(['resources/css/app.css', 'resources/js/app.js'])</head><body>PROBE OK</body></html>
BLADE

echo "=================================================================="
echo " does the 200 in case C actually work for a browser?"
echo "=================================================================="
printf 'http://127.0.0.1:5173' > public/hot
start_server
echo "  the page returns 200 and asks the browser to fetch:"
curl -s "$BASE/probe" | grep -oE 'src="[^"]*"|href="[^"]*"' | sed 's/^/    /'
echo
echo "  fetching that dev-server URL, as the browser would:"
curl -s -o /dev/null -w "    http://127.0.0.1:5173/@vite/client -> %{http_code} (%{errormsg})\n" \
  --max-time 5 "http://127.0.0.1:5173/@vite/client" 2>/dev/null \
  || echo "    http://127.0.0.1:5173/@vite/client -> connection refused (nothing is listening)"
stop_server
rm -f public/hot

echo
echo "=================================================================="
echo " where does 'npm run dev' put the hot file, and does build clear it?"
echo "=================================================================="
echo "  hotFile() resolves to: public/hot  (Vite.php:239, public_path('/hot'))"
npm run build >/tmp/b.log 2>&1
printf 'http://127.0.0.1:5173' > public/hot
npm run build >/tmp/b2.log 2>&1
if [ -f public/hot ]; then
  echo "  after 'npm run build' with a hot file present: STILL THERE"
else
  echo "  after 'npm run build' with a hot file present: removed by the build"
fi
rm -f public/hot

echo
echo "=== done ==="
