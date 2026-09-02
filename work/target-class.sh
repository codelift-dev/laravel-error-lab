#!/usr/bin/env bash
# Reproduce the ways a Laravel 13 app answers "Target class [X] does not exist."
#
# The advice for this message has been stable for a decade: run
# composer dump-autoload, and uncomment $namespace in RouteServiceProvider.
# Laravel 11 deleted RouteServiceProvider from the skeleton, so half of that
# advice cannot be followed at all on a current application. The other half is
# the fix for a case most people are not in.
#
# The question here is therefore not "does it fail". It is:
#   - which distinct causes produce this exact message,
#   - which produce a different message that gets mistaken for it,
#   - and whether composer dump-autoload changes any of them.
#
# Everything runs in Docker on a case-sensitive filesystem, which is the only
# way to observe the cause that cannot reproduce on Windows or macOS.
set -uo pipefail

APP=/build/target-app
BASE=http://127.0.0.1:8000
LOG=$APP/storage/logs/laravel.log

# The application is built inside the container, NOT under /lab.
#
# /lab is a bind mount from the host, and on a Windows or macOS host that
# mount is case-insensitive even though the container is Linux. The first run
# of this script put the app there and case E "passed": class_exists() for
# App\Http\Controllers\ProbeController returned true from a file named
# Probecontroller.php, and Reflection reported a filename that did not exist.
# The one cause this scenario is here to demonstrate had been silently
# neutralised by the mount. /build is the container's own filesystem.
if [ ! -d "$APP" ]; then
  mkdir -p /build && cd /build
  echo "=== creating the application ==="
  composer create-project laravel/laravel target-app --no-interaction --quiet
fi

cd "$APP"
echo "=== versions ==="
php artisan --version
php --version | head -1
composer --version 2>/dev/null | head -1
# Probe the filesystem the application actually lives on, not /tmp.
touch "$APP/CaseProbe"
if [ -e "$APP/caseprobe" ]; then
  echo "filesystem under $APP: case-INsensitive  <-- case E cannot reproduce here"
else
  echo "filesystem under $APP: case-sensitive"
fi
rm -f "$APP/CaseProbe"
echo

# --- harness ----------------------------------------------------------------
#
# APP_DEBUG is forced off, and that is not cosmetic. With APP_DEBUG=true the
# PHP built-in server (both "artisan serve" and plain "php -S") closes the
# connection without a response while rendering the debug page: curl reports
# 000, the access log records nothing, and the process is gone for every later
# request. It looks exactly like the application crashing. It is the
# single-threaded dev server failing to render the debug page, and it made the
# first run of this script produce a page of 000s that meant nothing.
#
# APP_DEBUG=false is also the configuration these errors are actually met in,
# so the statuses below are the ones production returns.
sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/' .env
php artisan config:clear >/dev/null 2>&1
grep '^APP_DEBUG' .env
echo

start_server() {
  php artisan config:clear >/dev/null 2>&1
  php artisan view:clear   >/dev/null 2>&1
  php artisan serve --host=127.0.0.1 --port=8000 >/tmp/serve.log 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    curl -s -o /dev/null --max-time 1 "$BASE/up" && return 0
    sleep 0.25
  done
  echo "server failed to start"; cat /tmp/serve.log; exit 1
}

stop_server() {
  # artisan serve spawns the built-in server as a child. Killing only the
  # parent leaves the child holding the port, and every later case then
  # measures the old process. That mistake produced two false findings in the
  # 419 run; see VERIFICATION.md.
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  pkill -f 'artisan serve' 2>/dev/null
  pkill -f 'php -S 127.0.0.1:8000' 2>/dev/null
  for _ in $(seq 1 60); do
    curl -s -o /dev/null --max-time 1 "$BASE/up" || { SERVER_PID=; return 0; }
    sleep 0.25
  done
  echo "port 8000 still held"; exit 1
}

# HTTP status, then the exception Laravel logged. Reading the log rather than
# scraping the HTML keeps the class name and message exact.
measure() {
  label="$1"; path="$2"
  : > "$LOG"
  code=$(curl -s -o /tmp/body.html -w '%{http_code}' --max-time 20 "$BASE$path")
  printf '%-58s HTTP %s\n' "$label" "$code"
  if [ -s "$LOG" ]; then
    head -1 "$LOG" | sed -E 's/^\[[^]]+\] [a-z]+\.[A-Z]+: //; s/ \{"exception".*//; s/^/    /'
    head -1 "$LOG" | grep -oE '\((Illuminate|Symfony|Error)[A-Za-z\\]*' | head -1 |
      sed -e 's/^(//' -e 's/^/    class: /'
  else
    echo "    (nothing logged)"
  fi
  echo
}

reset_app() {
  rm -rf app/Http/Controllers/Probe*.php app/Http/Controllers/probe*.php app/Contracts
  printf '%s\n' \
    '<?php' \
    '' \
    'use Illuminate\Support\Facades\Route;' \
    '' \
    "Route::get('/', fn () => 'root');" > routes/web.php
  php artisan route:clear  >/dev/null 2>&1
  php artisan config:clear >/dev/null 2>&1
}

# route_to <fully-qualified-class>
route_to() {
  printf '%s\n' \
    '<?php' \
    '' \
    'use Illuminate\Support\Facades\Route;' \
    '' \
    "Route::get('/probe', ['$1', 'index']);" > routes/web.php
}

# write_controller <file> <namespace> <class>
write_controller() {
  mkdir -p app/Http/Controllers
  printf '%s\n' \
    '<?php' \
    '' \
    "namespace $2;" \
    '' \
    "class $3" \
    '{' \
    '    public function index(): string' \
    '    {' \
    "        return 'PROBE OK';" \
    '    }' \
    '}' > "app/Http/Controllers/$1"
}

echo "########## 1. the baseline, and the string-action forms ##########"
reset_app
write_controller ProbeController.php 'App\Http\Controllers' ProbeController
printf '%s\n' \
  '<?php' \
  '' \
  'use App\Http\Controllers\ProbeController;' \
  'use Illuminate\Support\Facades\Route;' \
  '' \
  "Route::get('/probe', [ProbeController::class, 'index']);" \
  "Route::get('/bare',  'ProbeController@index');" \
  "Route::get('/fqcn',  'App\Http\Controllers\ProbeController@index');" > routes/web.php
start_server
measure "A. [Class::class, 'method'] - correct in every way" /probe
measure "B. 'ProbeController@index' - bare name, no namespace" /bare
measure "C. 'App\\Http\\Controllers\\ProbeController@index'" /fqcn
stop_server

echo "########## 2. the file does not declare what PSR-4 expects ##########"
reset_app
# Right directory, wrong namespace inside the file.
write_controller ProbeController.php 'App\Http\Controller' ProbeController
route_to 'App\Http\Controllers\ProbeController'
start_server
measure "D. namespace in the file does not match its directory" /probe
stop_server

reset_app
# Class name and file name differ only in case. Resolves on a case-insensitive
# filesystem (macOS, Windows); cannot resolve on Linux. This is the cause that
# passes every local check and fails only once deployed.
write_controller Probecontroller.php 'App\Http\Controllers' ProbeController
route_to 'App\Http\Controllers\ProbeController'
start_server
measure "E. file name differs from class name only in case" /probe
stop_server
rm -f app/Http/Controllers/Probecontroller.php

echo "########## 3. does composer dump-autoload matter? ##########"
reset_app
write_controller ProbeController.php 'App\Http\Controllers' ProbeController
route_to 'App\Http\Controllers\ProbeController'
echo "  (controller written; composer dump-autoload deliberately NOT run)"
start_server
measure "F. new controller file, autoloader never regenerated" /probe
stop_server

echo "  running: composer dump-autoload --classmap-authoritative"
composer dump-autoload --classmap-authoritative --quiet
rm -f app/Http/Controllers/ProbeController.php
write_controller ProbeLateController.php 'App\Http\Controllers' ProbeLateController
route_to 'App\Http\Controllers\ProbeLateController'
start_server
measure "G. new file added after --classmap-authoritative" /probe
stop_server

echo "  running: composer dump-autoload"
composer dump-autoload --quiet
start_server
measure "H. same file, after a plain composer dump-autoload" /probe
stop_server
rm -f app/Http/Controllers/ProbeLateController.php

echo "########## 4. the two messages this one gets confused with ##########"
reset_app
mkdir -p app/Contracts
printf '%s\n' \
  '<?php' '' 'namespace App\Contracts;' '' 'interface Reporter' '{' \
  '    public function report(): string;' '}' > app/Contracts/Reporter.php
mkdir -p app/Http/Controllers
printf '%s\n' \
  '<?php' '' 'namespace App\Http\Controllers;' '' 'use App\Contracts\Reporter;' '' \
  'class ProbeUnboundController' '{' \
  '    public function __construct(private Reporter $reporter) {}' '' \
  '    public function index(): string' '    {' \
  '        return $this->reporter->report();' '    }' '}' \
  > app/Http/Controllers/ProbeUnboundController.php
printf '%s\n' \
  '<?php' '' 'namespace App\Http\Controllers;' '' \
  'class ProbeAbsentController' '{' \
  '    public function __construct(private \App\Contracts\Absent $absent) {}' '' \
  '    public function index(): string' '    {' \
  "        return 'PROBE OK';" '    }' '}' \
  > app/Http/Controllers/ProbeAbsentController.php
printf '%s\n' \
  '<?php' '' 'use Illuminate\Support\Facades\Route;' '' \
  "Route::get('/unbound', ['App\Http\Controllers\ProbeUnboundController', 'index']);" \
  "Route::get('/absent',  ['App\Http\Controllers\ProbeAbsentController', 'index']);" \
  > routes/web.php
start_server
measure "I. constructor needs an interface that exists, unbound" /unbound
measure "J. constructor needs a class that does not exist" /absent
stop_server

echo "########## 5. the route cache holds the old name ##########"
reset_app
write_controller ProbeController.php 'App\Http\Controllers' ProbeController
route_to 'App\Http\Controllers\ProbeController'
php artisan route:cache >/dev/null 2>&1
echo "  routes cached. Now the class is renamed AND routes/web.php updated,"
echo "  which is what a rename commit actually contains."
rm -f app/Http/Controllers/ProbeController.php
write_controller ProbeRenamedController.php 'App\Http\Controllers' ProbeRenamedController
route_to 'App\Http\Controllers\ProbeRenamedController'
# Deliberately not clearing the route cache: this is the deploy that ships a
# rename while bootstrap/cache/routes-v7.php still names the old class.
php artisan config:clear >/dev/null 2>&1
php artisan serve --host=127.0.0.1 --port=8000 >/tmp/serve.log 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do curl -s -o /dev/null --max-time 1 "$BASE/up" && break; sleep 0.25; done
measure "K. cached route still names the pre-rename class" /probe
echo "  running: composer dump-autoload  (the advice everyone gives)"
composer dump-autoload --quiet
measure "L. after composer dump-autoload, cache untouched" /probe
stop_server
echo "  running: php artisan route:clear"
php artisan route:clear >/dev/null 2>&1
start_server
measure "M. after php artisan route:clear" /probe
stop_server

reset_app
rm -f app/Http/Controllers/ProbeRenamedController.php
sed -i 's/^APP_DEBUG=.*/APP_DEBUG=true/' .env
echo "=== done ==="
