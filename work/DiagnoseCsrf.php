<?php

namespace App\Http\Middleware;

use App\Support\CsrfDiagnosis;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Records the state of the session cookie before anything consumes it.
 *
 * Must be prepended to the web group so it runs ahead of EncryptCookies and
 * StartSession. See CsrfDiagnosis for why later is too late.
 */
class DiagnoseCsrf
{
    public function handle(Request $request, Closure $next): Response
    {
        $request->attributes->set(
            CsrfDiagnosis::ATTRIBUTE,
            CsrfDiagnosis::capture($request),
        );

        return $next($request);
    }
}
