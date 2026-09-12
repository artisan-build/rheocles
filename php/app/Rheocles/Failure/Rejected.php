<?php

namespace App\Rheocles\Failure;

/**
 * Any other non-2xx, with the protocol's stable `code` — named `reason`
 * here because `Exception::$code` is already taken, and is an int.
 */
final class Rejected extends Failure
{
    public function __construct(
        public readonly int $status,
        public readonly string $reason,
        public readonly string $error,
    ) {
        parent::__construct("$status $reason: $error", $status);
    }
}
