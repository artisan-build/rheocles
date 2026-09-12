<?php

namespace App\Rheocles\Failure;

/** The daemon answered 401: our token is stale or missing. */
final class Unauthorized extends Failure
{
    public function __construct()
    {
        parent::__construct('token refused (401)');
    }
}
