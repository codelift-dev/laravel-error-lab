<?php

/**
 * Wires the diagnostic into bootstrap/app.php.
 *
 * Two registrations are needed, and both have a non-obvious requirement.
 *
 * 1. The middleware must be PREPENDED to the web group. Appending puts it
 *    after EncryptCookies and StartSession, by which point the evidence that
 *    separates a rotated APP_KEY from an expired session has been destroyed.
 *
 * 2. The render callback cannot be typed on TokenMismatchException. It would
 *    never fire: Handler::render() calls prepareException() first, and that
 *    rewrites TokenMismatchException into HttpException(419) before the render
 *    callbacks are consulted. The original survives as the previous exception,
 *    which is what the check below matches on — more precise than trusting a
 *    419 status code that other code could also produce.
 */

$path = $argv[1] ?? 'bootstrap/app.php';
$source = file_get_contents($path);

if ($source === false) {
    fwrite(STDERR, "cannot read {$path}\n");
    exit(1);
}

if (str_contains($source, 'CsrfDiagnosis')) {
    echo "already installed\n";
    exit(0);
}

$middlewareNeedle = '->withMiddleware(function (Middleware $middleware): void {';
$exceptionNeedle = '->withExceptions(function (Exceptions $exceptions): void {';

foreach ([$middlewareNeedle, $exceptionNeedle] as $needle) {
    if (! str_contains($source, $needle)) {
        fwrite(STDERR, "block not found in {$path}: {$needle}\n");
        exit(1);
    }
}

$middleware = <<<'PHP'

        $middleware->web(prepend: [
            \App\Http\Middleware\DiagnoseCsrf::class,
        ]);
PHP;

$renderer = <<<'PHP'

        $exceptions->render(function (\Symfony\Component\HttpKernel\Exception\HttpException $e, \Illuminate\Http\Request $request) {
            if ($e->getStatusCode() !== 419
                || ! $e->getPrevious() instanceof \Illuminate\Session\TokenMismatchException) {
                return null;
            }

            return response('DIAGNOSIS: '.\App\Support\CsrfDiagnosis::explain($request)."\n", 419);
        });
PHP;

$source = str_replace($middlewareNeedle, $middlewareNeedle.$middleware, $source);
$source = str_replace($exceptionNeedle, $exceptionNeedle.$renderer, $source);

file_put_contents($path, $source);

echo "installed\n";
