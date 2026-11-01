<?php
// Sends OverPass's sign-in mails and e-mail updates, for the site worker on overpass.arctim.no. Lives on the web host because its mail
// server already signs and sends for arctim.no.
//
// POST { to, kind, code } or { to, kind, game, comment, stop }, Authorization: Bearer <token>. The token is in ~/overpass-mail.token, outside the web root,
// and is the worker's MAIL_TOKEN secret. Only the texts below can be sent, and what fills them has to look like a code,
// a game's ID or a token, so a leaked token can't send anything else, and the daily cap limits what it could do. Updates
// stop short of the cap, so they can't use up the day's sign-in codes. Nothing is stored but a count for the day.

const SENDER = 'noreply@arctim.no';
const DAILY_CAP = 300;
const UPDATES_CAP = 200;

$texts = [
    'signup' => ['Your OverPass code', "Your code for creating an OverPass account:\n\n{code}\n\nIt works for 10 minutes. If this wasn't you, ignore this mail: no account is made without it."],
    'signin' => ['Your OverPass code', "Your code for signing in to OverPass:\n\n{code}\n\nIt works for 10 minutes. If this wasn't you, someone has your password: reset it at https://overpass.arctim.no/auth/email?mode=reset"],
    'reset' => ['Your OverPass code', "Your code for choosing a new OverPass password:\n\n{code}\n\nIt works for 10 minutes. If this wasn't you, ignore this mail: your password stays as it is."],
    'exists' => ['Your OverPass account', "Someone tried to make an OverPass account with this address, but you already have one.\n\nSign in at https://overpass.arctim.no/account, or choose a new password at https://overpass.arctim.no/auth/email?mode=reset\n\nIf this wasn't you, ignore this mail."],
    'updates' => ['Your OverPass code', "Your code for turning on OverPass e-mail updates:\n\n{code}\n\nIt works for 10 minutes. If this wasn't you, ignore this mail: nothing is sent to this address without it."],
];
$updates = [
    'reply' => ['New reply on OverPass', "Someone replied in a thread of yours on OverPass:\n\n{link}"],
    'comment' => ['New comment on OverPass', "Someone commented on a game you rated on OverPass:\n\n{link}"],
    'fixed' => ['Your OverPass report is fixed', "An issue you reported on OverPass is marked as fixed:\n\n{link}\n\nThe fix may reach you in the next update."],
];

function answer(int $status): void {
    http_response_code($status);
    exit;
}

$home = dirname(__DIR__, 4);
$token = trim((string) @file_get_contents("$home/overpass-mail.token"));
$given = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
if ($_SERVER['REQUEST_METHOD'] !== 'POST') answer(405);
if (strlen($token) < 32 || !hash_equals("Bearer $token", $given)) answer(403);

$mail = json_decode((string) file_get_contents('php://input'), true);
$to = $mail['to'] ?? '';
$kind = $mail['kind'] ?? '';
$code = $mail['code'] ?? '';
// FILTER_VALIDATE_EMAIL takes no newlines, so the address can't add headers.
if (!is_string($to) || !filter_var($to, FILTER_VALIDATE_EMAIL) || (!isset($texts[$kind]) && !isset($updates[$kind]))) answer(400);
$update = isset($updates[$kind]);
if ($update) {
    $game = $mail['game'] ?? '';
    $comment = $mail['comment'] ?? '';
    $stop = $mail['stop'] ?? '';
    if (!is_string($game) || !preg_match('/\A[a-z0-9-]{1,120}\z/', $game)) answer(400);
    if (!is_string($stop) || !preg_match('/\A[\w-]{43}\z/', $stop)) answer(400);
    if ($kind !== 'fixed' && (!is_string($comment) || !preg_match('/\A[0-9a-f-]{36}\z/', $comment))) answer(400);
} elseif ($kind !== 'exists' && (!is_string($code) || !preg_match('/\A[A-Z2-9]{6}\z/', $code))) answer(400);

$counter = fopen("$home/overpass-mail.count", 'c+');
if (!$counter || !flock($counter, LOCK_EX)) answer(500);
[$day, $count] = array_pad(explode(' ', (string) fread($counter, 64)), 2, 0);
$today = gmdate('Y-m-d');
$count = $day === $today ? (int) $count : 0;
if ($count >= ($update ? UPDATES_CAP : DAILY_CAP)) answer(429);
ftruncate($counter, 0);
rewind($counter);
fwrite($counter, "$today " . ($count + 1));
flock($counter, LOCK_UN);

[$subject, $body] = $update ? $updates[$kind] : $texts[$kind];
$headers = 'From: OverPass <' . SENDER . ">\r\nContent-Type: text/plain; charset=utf-8\r\nAuto-Submitted: auto-generated";
if ($update) {
    $site = 'https://overpass.arctim.no';
    $link = "$site/games/$game" . ($kind === 'fixed' ? '' : "#comment-$comment");
    $stopLink = "$site/updates/stop/$stop";
    $body = str_replace('{link}', $link, $body) . "\n\nStop these mails: $stopLink";
    $headers .= "\r\nList-Unsubscribe: <$stopLink>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click";
}
answer(mail($to, $subject, str_replace('{code}', (string) $code, $body), $headers, '-f' . SENDER) ? 204 : 502);
