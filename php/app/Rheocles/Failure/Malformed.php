<?php

namespace App\Rheocles\Failure;

final class Malformed extends Failure
{
    public function __construct(string $why)
    {
        parent::__construct("malformed answer — $why");
    }
}
