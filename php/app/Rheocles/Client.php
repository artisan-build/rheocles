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

    /** `POST /streams/{id}/arm` — device live or not; never stamps. */
    public function arm(string $id, bool $armed): array
    {
        return $this->post('/streams/'.rawurlencode($id).'/arm', ['armed' => $armed]);
    }

    /** `POST /record` — create and start in one; the popover's button. */
    public function record(array $body = []): array
    {
        return $this->post('/record', (object) $body);
    }

    public function stop(string $takeId): array
    {
        return $this->post('/takes/'.rawurlencode($takeId).'/stop', (object) []);
    }

    /** `GET /takes/{id}` — the manifest, live while recording. */
    public function take(string $id): array
    {
        return $this->get('/takes/'.rawurlencode($id));
    }

    /** `GET /takes` — recent takes, newest first. */
    public function takes(): array
    {
        return $this->get('/takes');
    }

    public function mark(string $takeId, string $label): array
    {
        return $this->post('/takes/'.rawurlencode($takeId).'/markers', ['label' => $label]);
    }

    // MARK: transport

    public function get(string $path): array
    {
        return $this->send('GET', $path, fn (PendingRequest $r) => $r->get($this->base().$path));
    }

    public function post(string $path, array|object $body): array
    {
        return $this->send('POST', $path, fn (PendingRequest $r) => $r->post($this->base().$path, $body));
    }

    /**
     * One request; the protocol's one error shape on every route. Guzzle
     * throws on connection failure and Laravel wraps it — that is
     * Unreachable, the case the lifecycle watches for.
     */
    private function send(string $method, string $path, \Closure $call): array
    {
        // Loopback: an answer that takes longer than this is a daemon that
        // is not going to answer.
        $request = Http::acceptJson()->timeout(2)->connectTimeout(1);
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
