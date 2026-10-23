# App signals protocol, v1

How KestrelKit (and any other app SDK) sends analytics signals to Keen Kestrel. KestrelKit and the
server (Keen Kestrel's `POST /ingest/v1/signals`) both follow this document; change it here first
when the protocol changes.

v1 started as a short agreement plus thirteen proposals (P1–P13). The server adopted all of them
except P11, which is still [open](#open-proposal-duplicates-p11). The adopted proposals are now part
of the text below, marked with their numbers so references in either code base still lead
somewhere. Where the server does more than an SDK needs to know, the text says **Server**.

## Request

```
POST {baseURL}/ingest/v1/signals
```

| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `X-Kestrel-Key` | The project's public key: the same 32 hex characters as the key in the project's DSN. |
| `Content-Encoding` | Optional. The server accepts `gzip`, `deflate`, `br` and `zstd` (and `identity`). Any other value is a `400`. |
| `User-Agent` | Optional. KestrelKit sends `KestrelKit/<version>`; the server doesn't store it (P12). |

No cookies are sent or accepted (P12). Apps send no `Origin` header. **Server:** if a request has
one, it must be one of the key's allowed origins, or the answer is `403`.

KestrelKit compresses bodies of 1 KB or more with gzip, and sends the compressed form only when it
is smaller (P3). It uses no other encoding.

### Body

```json
{"sent_at":"2026-10-22T19:00:00.000Z","sdk":{"name":"kestrelkit","version":"0.1.0"},
 "signals":[{"type":"App.launched","time":"2026-10-22T18:59:58.123Z",
   "install_id":"8F3C…-UUID","session_id":"UUID",
   "app":{"bundle_id":"com.example.app","version":"1.4.0","build":"57"},
   "device":{"platform":"iOS","os_version":"18.2","model":"iPhone16,2","locale":"nb_NO"},
   "flags":{"debug":false,"testflight":false,"simulator":false},
   "payload":{"plan":"pro"}}]}
```

| Field | Required | Meaning |
|---|---|---|
| `signals` | yes | An array of at most 100 signals. |
| `sent_at` | no | When the batch was sent, from the device clock (RFC 3339). Used to correct clock skew. |
| `sdk` | no | The SDK's `name` and `version`, for diagnostics. |
| `type` | yes | What happened, such as `Paywall.shown`. See [Limits](#limits). |
| `install_id` | yes | A random id for the install; KestrelKit sends an upper-case UUID it creates once. The server stores only a keyed hash of it, never the raw value. |
| `session_id` | no | A random id for the session (KestrelKit: an upper-case UUID). Without one, the signal belongs to no session. |
| `time` | no | When the signal happened, from the device clock (RFC 3339; KestrelKit sends UTC with milliseconds). Without a readable one, the server uses the time the batch arrived. |
| `app` | no | `bundle_id`, `version`, `build`. |
| `device` | no | `platform` (`iOS`, `iPadOS`, `macOS`, `visionOS`, `watchOS` or `tvOS`), `os_version`, `model`, `locale`. |
| `flags` | no | `debug`, `testflight`, `simulator`. A missing flag is `false`; only a JSON `true` sets one. |
| `payload` | no | A flat object of strings. A missing payload means `{}`. |

Unknown fields are ignored, so SDKs can add fields without breaking older servers. An unknown
`platform` is stored as given, not rejected (P6).

## Limits

"Characters" are Unicode scalar values (Rust's `char`), not bytes and not grapheme clusters (P1).
KestrelKit cuts strings at whole grapheme clusters within that count, so it never sends half an
emoji.

| What | Limit |
|---|---|
| Signals per request | 100. |
| Body | 256 KB (262,144 bytes) of JSON before compression, and no more than that compressed (P2). The server caps the decompressed size too, which also protects it from gzip bombs. |
| `type` | 1–100 characters from `[A-Za-z0-9._-]`. |
| `install_id`, `session_id` | Opaque strings of at most 64 characters (P4). |
| `bundle_id`, `version`, `build`, `os_version`, `model`, `locale` | At most 200 characters each, without control characters (P4). |
| `payload` | At most 20 keys. Keys are up to 40 characters; values are strings up to 200 characters. |

KestrelKit applies every limit on the device, so the server never has to fix or drop a signal it
sends:

- It trims the `type` and turns every character outside `[A-Za-z0-9._-]` into `_` (`Paywall shown`
  is sent as `Paywall_shown`), then cuts it to 100 characters. An empty type isn't sent. This
  matters, because the server drops a signal whose type has other characters (see below).
- It converts numbers and booleans in payloads to strings (`12`, `true`), puts the signal's own keys
  before the default payload's, and drops keys that name an IP address or a user agent (see
  [Scrubbing](#scrubbing-p13)).
- It removes control characters from the other strings, trims them and cuts them to 200.

### Lenient per signal, strict per batch (P5)

The server answers `400` only when the body isn't JSON or has no `signals` array, and `413` when it
has more than 100 signals or is too large. Otherwise it fixes or drops each signal on its own:

| A signal that … | The server … |
|---|---|
| isn't a JSON object | drops it. |
| has no `type`, an empty one, or one with a character outside `[A-Za-z0-9._-]` | drops it. It doesn't map characters to `_`; SDKs should, as KestrelKit does. |
| has a `type` over 100 characters | cuts it to 100. |
| has no `install_id`, or a blank one | drops it. |
| has an `install_id` or `session_id` over 64 characters | cuts it to 64. |
| has no `time`, or one it can't read | uses the time the batch arrived. |
| is older than the project's raw retention once its time is corrected | drops it (see [Clock skew](#clock-skew-p10)). |
| has text with control characters or over 200 characters | removes them and cuts the text to 200. |
| has numbers or booleans as payload values | stores them as strings (`12`, `true`). |
| has objects, arrays or `null` as payload values | drops those keys. |
| has more than 20 payload keys | keeps the first 20 it reads. |
| has payload keys over 40 characters | cuts them to 40. Empty keys and keys that name an IP address or a user agent are dropped. |

The `202` answer counts the signals that were stored, and says how many were dropped when some
were (see [Responses](#responses)).

## Clock skew (P10)

Device clocks can be wrong. When `server_now − sent_at` is more than **5 seconds** either way, the
server moves every `time` in the batch by that difference; smaller differences are network delay
and are left alone. Without a readable `sent_at`, nothing is moved. A signal without a readable
`time` gets the time the batch arrived, and times still in the future are set to the server's now.

Signals older than the project's raw-signal retention after the correction (30 days unless the
project says otherwise) are dropped.

## Scrubbing (P13)

Both sides replace payload values that look like personal data with `[Filtered]`, with the same
rules (Keen Kestrel's `src/analytics/clean.rs` and `src/event/scrub.rs`, KestrelKit's
`Scrubber.swift`), in this order:

1. Card numbers: 13–19 digits, optionally grouped by single spaces or dashes, that pass the Luhn
   check.
2. `Bearer …` and `Basic …` credentials. The scheme stays: `Bearer [Filtered]`.
3. `name=value` pairs whose name contains `pass`, `secret`, `token`, `auth`, `key`, `card` or
   `cookie`: `token=abc` becomes `token=[Filtered]`.
4. Email addresses.
5. IP addresses: IPv4, and IPv6 written out with at least four groups (`2001:db8:0:0:1:0:0:1`).
   Shortened IPv6 with `::` isn't recognised.
6. Phone numbers: 9–15 digits that start with `+` or `00`, or are written in at least three groups.
   Plain digit runs (order numbers, ids), dates and versions are kept.

Payload keys that name an IP address or a user agent are dropped with their values. The keys,
compared ignoring ASCII case, are:

- `ip`, `ip_address`, `client_ip`, `remote_addr`;
- the forwarding headers `x-forwarded-for`, `x-real-ip`, `forwarded`, `cf-connecting-ip`,
  `true-client-ip`, `x-client-ip`, `x-cluster-client-ip`, `fastly-client-ip`, and their CGI forms
  `http_x_forwarded_for`, `http_x_real_ip`, `http_forwarded`, `http_cf_connecting_ip`,
  `http_true_client_ip`, `http_x_client_ip`;
- `user-agent`, `user_agent`, `http_user_agent`.

KestrelKit scrubs on the device, before a signal is queued. The server scrubs again, so older or
other SDKs are covered too. Scrubbing is a safety net: apps should keep personal data out of
payloads.

## Responses

| Status | Meaning | What KestrelKit does |
|---|---|---|
| `202 {"accepted": n}` | Done: `n` signals were stored. When some were dropped (P5), the body also has `"dropped": m`. | Forgets the batch. Logs `dropped` in debug builds; never resends. |
| other `2xx` | Done. | Forgets the batch. |
| `400` | The batch is malformed: not JSON, no `signals` array, or an unknown or broken `Content-Encoding`. | Drops it and doesn't retry. |
| `401` | No key, or an unknown one. | Stops sending until the next launch and keeps the queue. Logs in debug builds only. |
| `403` | The key is disabled, app analytics is off for the project, or the `Origin` header isn't allowed. | As `401`. |
| `404` | The server has no app-signal ingest (an older Kestrel). | As `401`, so the signals arrive once the server is upgraded (P7). |
| `408` | Request timeout. | Retries like a `5xx` (P7). |
| `413` | More than 100 signals, or more than 256 KB, compressed or not. | Splits the batch and retries the halves; drops a single signal that is still too large. |
| `429` | A rate limit: the server's per-IP limit or the key's `rate_limit_per_minute`. Both count requests, not signals. | Waits `Retry-After` seconds. |
| `503` | The server's write queue is full, or it briefly can't take signals. | Waits `Retry-After` seconds. |
| other `4xx` | | As `400` (P7). |
| other `5xx`, network error | Something went wrong. | Keeps the batch and retries with backoff. |

SDKs treat any `2xx` as done, whatever `n` and `m` are, so they never resend a batch the server has
seen (P5, P7). Error responses have a `{"detail": "…"}` body meant for people; SDKs don't need to
read it. All answers carry `Cache-Control: no-store`.

**Retry-After (P8).** `429` and `503` carry `Retry-After` in seconds. KestrelKit reads it as a number
of seconds (an HTTP date falls back to backoff) and never waits longer than 1 hour, whatever the
header says. Without it, KestrelKit backs off exponentially: from 30 seconds, doubling up to 1 hour,
with up to 20 % jitter. A success resets the backoff.

**Server:** the checks run in this order: the per-IP limit (`429`), the key (`401`, `403`), the
`Origin` (`403`), the key's limit (`429`), the body's size (`413`), its encoding and JSON (`400`), the
number of signals (`413`), and then each signal on its own.

## Reserved signal types and sessions (P9)

KestrelKit sends two signals by itself (an app can turn them off):

- `App.launched` when the app starts (the first signal of a new session).
- `Session.started` when a new session starts after the app was in the background for 5 minutes or
  more.

The server counts sessions as distinct `session_id` values; these two signals make sure every
session has at least one signal. Types starting with `App.`, `Session.` or `Kestrel.` are reserved
for SDKs.

## Test signals

Signals with the `debug`, `testflight` or `simulator` flag are stored like any other, but the server
leaves them out of the dashboards by default; the App tab's "include test signals" filter shows
them. KestrelKit sets `debug` for debug builds and in test mode, unless the app chose to keep such
signals on the device instead.

## Open proposal: duplicates (P11)

If a response is lost after the server stored a batch, the SDK sends the batch again. That is rare
and harmless for trends, so v1 accepts it. A later version (v1.1) could add an optional `batch_id`
(a UUID) to the body so the server can ignore a batch it has already stored. KestrelKit doesn't send
one, and today's server ignores the field like any unknown field.
