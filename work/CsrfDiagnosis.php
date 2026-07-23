<?php

namespace App\Support;

use Illuminate\Contracts\Encryption\DecryptException;
use Illuminate\Cookie\CookieValuePrefix;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Crypt;

/**
 * Works out WHY CSRF verification failed.
 *
 * Six distinct causes all produce the same bare "419 Page Expired", so the
 * usual checklist advice cannot be acted on — nothing in the response tells
 * you which one you have.
 *
 * This has to run as middleware, ahead of StartSession, and cannot be done
 * from the exception handler alone. Two pieces of evidence are destroyed
 * before the handler ever sees the request:
 *
 *   - EncryptCookies sets a cookie it failed to decrypt to null rather than
 *     removing it, so `$request->cookies->has()` still reports true and a
 *     rotated APP_KEY looks identical to a healthy request.
 *   - StartSession has already created a fresh session by then, complete with
 *     a new token, so an expired session is indistinguishable from a live one
 *     that simply received the wrong token.
 *
 * Registering it after StartSession therefore reports TOKEN_MISMATCH for
 * everything, which is exactly the useless answer we are trying to replace.
 */
class CsrfDiagnosis
{
    public const ATTRIBUTE = 'csrf_diagnosis';

    /**
     * Capture the evidence. Call this from middleware placed BEFORE
     * EncryptCookies and StartSession.
     *
     * @return array{cookie_sent: bool, decrypted: bool, session_id: ?string, session_exists: bool}
     */
    public static function capture(Request $request): array
    {
        $name = (string) config('session.cookie');
        $raw = $request->cookies->get($name);

        $facts = [
            'cookie_sent' => $raw !== null,
            'decrypted' => false,
            'session_id' => null,
            'session_exists' => false,
        ];

        if ($raw === null) {
            return $facts;
        }

        try {
            $id = CookieValuePrefix::remove(Crypt::decrypt($raw, false));
        } catch (DecryptException) {
            return $facts;
        }

        $facts['decrypted'] = true;
        $facts['session_id'] = $id;

        // Read straight from the session store. This is the only moment the
        // answer is still available: StartSession is about to create a
        // replacement session if this read comes back empty.
        $payload = app('session')->driver()->getHandler()->read($id);
        $facts['session_exists'] = $payload !== '' && $payload !== false;

        return $facts;
    }

    /**
     * Turn the captured evidence into a cause.
     */
    public static function explain(Request $request): string
    {
        $submitted = $request->input('_token') !== null
            || $request->header('X-CSRF-TOKEN') !== null;

        if (! $submitted) {
            return 'NO_TOKEN_SUBMITTED: the form is missing @csrf, or the '
                .'AJAX call omits the X-CSRF-TOKEN header';
        }

        $facts = $request->attributes->get(self::ATTRIBUTE);

        if ($facts === null) {
            return 'UNKNOWN: the diagnostic middleware did not run — it must '
                .'be prepended to the web group, ahead of EncryptCookies';
        }

        if (! $facts['cookie_sent']) {
            return 'NO_SESSION_COOKIE: the browser never sent one — blocked '
                .'cookies, a SameSite/Secure mismatch, or a wrong SESSION_DOMAIN';
        }

        if (! $facts['decrypted']) {
            return 'COOKIE_UNDECRYPTABLE: APP_KEY no longer matches the key '
                .'that issued this cookie — rotated on deploy, or servers disagree';
        }

        if (! $facts['session_exists']) {
            return 'SESSION_GONE: the cookie was valid but its server-side '
                .'session no longer exists — expired, garbage-collected, or the '
                .'store is not shared across servers';
        }

        return 'TOKEN_MISMATCH: the session is alive and was found, but the '
            .'submitted token belongs to a different one — a stale tab, a '
            .'back-button replay, or a second login elsewhere';
    }
}
