<?php

namespace App\Rheocles\Failure;

/** Nothing is listening, or the connection was refused or reset. */
final class Unreachable extends Failure
{
    public function __construct(string $why)
    {
        parent::__construct("unreachable — $why");
    }
}
