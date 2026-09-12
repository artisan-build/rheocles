<?php

use App\Rheocles\Token;

it('masks a token to its ends', function () {
    expect(Token::masked('3f9a1c77e2b04d5f8a6c1e2d9b7f4a0c'))->toBe('3f9a1c…7f4a0c')
        ->and(Token::masked('short'))->toBe('short')
        ->and(Token::masked(null))->toBeNull();
});
