<?php

namespace App\Rheocles;

/**
 * `GET /events`, read as server-sent events, from PHP.
 *
 * This is the watcher's copy, not the popover's: the popover's web view
 * holds its own EventSource (brief, rule 2) and PHP is never between the
 * daemon and the DOM. `rheo:watch` reads the same stream for one purpose —
 * to set the menu bar icon while the popover is closed — and this is the
 * smallest reader that does it: a loopback socket, the request written by
 * hand, `data:` lines gathered until a blank line (PROTOCOL § Events). The
 * daemon answers with no transfer encoding, so lines are lines.
 *
 * `read()` yields one decoded event at a time, or null when `idle` seconds
 * pass with nothing said, so the caller can take a pulse between events.
 * It returns when the daemon closes the stream.
 */
final class EventStream
{
    /** @return \Generator<int, array|null> */
    public static function read(string $host, int $port, string $token, float $idle = 3.0): \Generator
    {
        $socket = @stream_socket_client("tcp://$host:$port", $errno, $error, 2);
        if ($socket === false) {
            throw new Failure\Unreachable("$error ($errno)");
        }
        stream_set_timeout($socket, (int) floor($idle), (int) (($idle - floor($idle)) * 1_000_000));

        fwrite($socket, "GET /events?access_token=".rawurlencode($token)." HTTP/1.1\r\n"
            ."Host: $host:$port\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n");

        // The status line and headers.
        $status = fgets($socket);
        if ($status === false || ! preg_match('~^HTTP/1\.\d (\d{3})~', $status, $m)) {
            fclose($socket);
            throw new Failure\Malformed('no status line on GET /events');
        }
        if ((int) $m[1] === 401) {
            fclose($socket);
            throw new Failure\Unauthorized;
        }
        if ((int) $m[1] !== 200) {
            fclose($socket);
            throw new Failure\Rejected((int) $m[1], 'unknown', trim($status));
        }
        while (($line = fgets($socket)) !== false && rtrim($line, "\r\n") !== '') {
            // Headers are not needed.
        }

        try {
            $data = '';
            while (true) {
                $line = fgets($socket);
                if ($line === false) {
                    if (stream_get_meta_data($socket)['timed_out'] ?? false) {
                        yield null;

                        continue;
                    }
                    break;  // The daemon closed the stream.
                }
                $line = rtrim($line, "\r\n");
                if ($line === '') {
                    if ($data !== '' && ($event = self::decode($data)) !== null) {
                        yield $event;
                    }
                    $data = '';
                } elseif (str_starts_with($line, 'data:')) {
                    $payload = ltrim(substr($line, 5), ' ');
                    $data .= ($data === '' ? '' : "\n").$payload;
                }
                // Comments (`: connected`) and other fields are ignored.
            }
            if ($data !== '' && ($event = self::decode($data)) !== null) {
                yield $event;
            }
        } finally {
            fclose($socket);
        }
    }

    /** The whole object, which always carries an `event` key naming its kind. */
    public static function decode(string $text): ?array
    {
        $json = json_decode($text, true);

        return is_array($json) && isset($json['event']) && is_string($json['event']) ? $json : null;
    }
}
