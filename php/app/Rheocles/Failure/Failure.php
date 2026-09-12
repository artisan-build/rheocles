<?php

namespace App\Rheocles\Failure;

/** What a call to the daemon can fail with; one subclass per cause. */
abstract class Failure extends \RuntimeException {}
