<?php

namespace App\Rheocles;

use App\Rheocles\Failure\Malformed;
use App\Rheocles\Failure\Rejected;
use App\Rheocles\Failure\Unauthorized;
use App\Rheocles\Failure\Unreachable;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Support\Facades\Http;

/**
 * The daemon's HTTP transport, from the client side.
 *
 * Everything the app shows comes out of this and everything it does goes in
 * through it (brief, rule 1). Nothing here knows about devices — it knows
 * paths, a token, and the one error shape docs/PROTOCOL.md promises on
 * every route. The popover's web view holds the event stream itself; this
 * class carries clicks and the pulse, which happen at human speed.
 */
final class Client
{
    public function __construct(
        public readonly string $host,
        public readonly int $port,
        public ?string $token = null,
    ) {}

    /** From config, with the token as the file has it right now. */
    public static function fromConfig(): self
    {
        return new self(config('rheocles.host'), config('rheocles.http_port'), Token::read());
    }

    public function base(): string
    {
        return "http://{$this->host}:{$this->port}";
    }

    /**
     * The event stream's URL. `EventSource` cannot set a header, so the
     * token goes in the query (PROTOCOL § Authentication).
     */
    public function eventsUrl(): ?string
    {
        return $this->token === null ? null : $this->base().'/events?access_token='.rawurlencode($this->token);
    }

    // MARK: commands, one per route

    /** `GET /` — who this daemon is, where files go, how much room there is. */
    public function discovery(): array
    {
        return $this->get('/');
    }

    /** `GET /streams` — every stream with armed state, plus permissions. */
    public function streams(): array
    {
        return $this->get('/streams');
    }

    /**
     * `POST /streams/{id}/arm` — device live or not; never stamps. Ids are
     * URL-safe by contract (`<kind>:<identifier>`, PROTOCOL § GET /streams)
     * and go on the path verbatim: the daemon does not decode `%3A`.
     */
    public function arm(string $id, bool $armed): array
    {
        return $this->post("/streams/$id/arm", ['armed' => $armed]);
    }

    /** `POST /record` — create and start in one; the popover's button. */
    public function record(array $body = []): array
    {
        return $this->post('/record', (object) $body);
    }

    public function stop(string $takeId): array
    {
        return $this->post("/takes/$takeId/stop", (object) []);
    }

    /** `GET /takes/{id}` — the manifest, live while recording. */
    public function take(string $id): array
    {
        return $this->get("/takes/$id");
    }

    /** `GET /takes` — recent takes, newest first. */
    public function takes(): array
    {
        return $this->get('/takes');
    }

    public function mark(string $takeId, string $label): array
    {
        return $this->post("/takes/$takeId/markers", ['label' => $label]);
    }

    /**
     * `POST /takes/{id}/reveal { path? }` → `204`: the take's folder in the
     * Finder, or one of its files when `path` names one (feature brief §1).
     * The daemon reveals — never the app: a browser front end cannot open
     * the Finder, and two native ones should not do it twice. The body is
     * `{}` for the folder and `{ "path": … }` for a file, exactly.
     */
    public function revealTake(string $takeId, ?string $path = null): void
    {
        $this->post("/takes/$takeId/reveal", $path === null ? (object) [] : ['path' => $path]);
    }

    /**
     * `POST /reveal { path }` → `204`: any path under the output root, the
     * root itself when empty — the settings panel's folder button.
     */
    public function reveal(string $path = ''): void
    {
        $this->post('/reveal', ['path' => $path]);
    }

    /**
     * `POST /takes/{id}/combine` → the manifest with `combined` pending:
     * the single-file mux after the fact, on any finished take with at
     * most one video (feature brief addendum). Completion arrives on the
     * `take` event, exactly as it does after stop.
     */
    public function combine(string $takeId): array
    {
        return $this->post("/takes/$takeId/combine", (object) []);
    }

    /** `GET /settings` — the daemon's output root, default codec and default combine. */
    public function settings(): array
    {
        return $this->get('/settings');
    }

    /** `PATCH /settings { outputRoot?, codec?, combine? }` → the full settings. */
    public function updateSettings(array $changes): array
    {
        return $this->send('PATCH', '/settings', fn (PendingRequest $r) => $r->patch($this->base().'/settings', $changes), timeout: 10);
    }

    /**
     * `POST /token/rotate` → `{ token }`. The old token is dead for every
     * request after the answer — including this client's, so the new one
     * goes straight into it; every other client reads the file again.
     */
    public function rotateToken(): string
    {
        $answer = $this->post('/token/rotate', (object) []);
        $token = (string) ($answer['token'] ?? '');
        if ($token === '') {
            throw new Malformed('POST /token/rotate: no token in the answer');
        }
        $this->token = $token;

        return $token;
    }

    /**
     * `GET /preview/{stream}` — one frame, on demand: JPEG bytes for video,
     * `{ levelDb }` for audio. Raw, with its content type; errors still come
     * in the protocol's shape and are thrown as such.
     */
    public function preview(string $id): array
    {
        $request = Http::timeout(5)->connectTimeout(1);
        if ($this->token !== null) {
            $request = $request->withToken($this->token);
        }
        try {
            $response = $request->get($this->base()."/preview/$id");
        } catch (ConnectionException $e) {
            throw new Unreachable($e->getMessage());
        }
        if ($response->status() === 401) {
            throw new Unauthorized;
        }
        if (! $response->successful()) {
            $body = $response->json();
            throw new Rejected($response->status(), is_array($body) ? ($body['code'] ?? 'unknown') : 'unknown',
                is_array($body) ? ($body['error'] ?? $response->body()) : $response->body());
        }

        return ['contentType' => (string) $response->header('Content-Type'), 'body' => $response->body()];
    }

    // MARK: transport

    /**
     * Reads answer at once or not at all: two seconds on loopback is a
     * daemon that is not going to answer, and the pulse should say so.
     */
    public function get(string $path): array
    {
        return $this->send('GET', $path, fn (PendingRequest $r) => $r->get($this->base().$path), timeout: 2);
    }

    /**
     * Commands touch hardware — arming spins a device up, stop finalizes
     * writers — and a busy CoreAudio can take more than two seconds to
     * hand a microphone over. Ten is patience, not a hang.
     */
    public function post(string $path, array|object $body): array
    {
        return $this->send('POST', $path, fn (PendingRequest $r) => $r->post($this->base().$path, $body), timeout: 10);
    }

    /**
     * One request; the protocol's one error shape on every route. Guzzle
     * throws on connection failure and Laravel wraps it — that is
     * Unreachable, the case the lifecycle watches for.
     */
    private function send(string $method, string $path, \Closure $call, int $timeout): array
    {
        $request = Http::acceptJson()->timeout($timeout)->connectTimeout(1);
        if ($this->token !== null) {
            $request = $request->withToken($this->token);
        }

        try {
            $response = $call($request);
        } catch (ConnectionException $e) {
            throw new Unreachable($e->getMessage());
        }

        $status = $response->status();
        if ($status >= 200 && $status < 300) {
            // `204` is an answer with nothing to say (reveal); every other
            // success is JSON, and a body that is not — empty included — is
            // a broken daemon, or a stranger on the port.
            if ($status === 204) {
                return [];
            }
            $json = $response->json();
            if (! is_array($json)) {
                throw new Malformed("$method $path: not JSON");
            }

            return $json;
        }
        if ($status === 401) {
            throw new Unauthorized;
        }
        $body = $response->json();
        throw new Rejected(
            $status,
            is_array($body) ? ($body['code'] ?? 'unknown') : 'unknown',
            is_array($body) ? ($body['error'] ?? $response->body()) : $response->body(),
        );
    }
}
