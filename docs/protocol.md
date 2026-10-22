# App signals protocol, v1

How KestrelKit (and any other app SDK) sends analytics signals to Keen Kestrel. KestrelKit and the
server both follow this document; change it here first when the protocol changes.

The first part is the agreed protocol. The second part, [Proposals](#proposals), lists the details
the first part leaves open, with what KestrelKit does today. They are proposals until the server
side agrees.

## Request

```
POST {baseURL}/ingest/v1/signals
```

Headers:

| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `X-Kestrel-Key` | The project's public key: the same 32 hex characters as the key in the project's DSN. |
| `Content-Encoding` | Optional: `gzip`. |

Body:

```json
{"sent_at":"2026-10-22T19:00:00.000Z","sdk":{"name":"kestrelkit","version":"0.1.0"},
 "signals":[{"type":"App.launched","time":"2026-10-22T18:59:58.123Z",
   "install_id":"8F3C…-UUID","session_id":"UUID",
   "app":{"bundle_id":"com.example.app","version":"1.4.0","build":"57"},
   "device":{"platform":"iOS","os_version":"18.2","model":"iPhone16,2","locale":"nb_NO"},
   "flags":{"debug":false,"testflight":false,"simulator":false},
   "payload":{"plan":"pro"}}]}
```

- `platform` is one of `iOS`, `iPadOS`, `macOS`, `visionOS`, `watchOS`, `tvOS`.
- `time` is when the signal happened, from the device clock. `sent_at` lets the server correct
  clock skew.
- The server hashes `install_id` with a per-project secret and never stores the raw value.

## Limits

- At most 100 signals per request and 256 KB of body.
- `type` is 1–100 characters from `[A-Za-z0-9._-]`.
- `payload` has at most 20 keys. Keys are up to 40 characters; values are strings up to 200
  characters. The SDK converts numbers and booleans to strings.

## Responses

| Status | Meaning | What the SDK does |
|---|---|---|
| `202 {"accepted": n}` | Done. | Forgets the batch. |
| `400` | The batch is malformed. | Drops it and doesn't retry. |
| `401`, `403` | Wrong or disabled key, or analytics turned off. | Stops sending until the next launch; logs in debug builds only. |
| `413` | Too large. | Splits the batch and retries the halves. |
| `429`, `503` | Slow down. | Waits `Retry-After` seconds, otherwise backs off exponentially (at most 1 hour). |
| other `5xx`, network error | Something went wrong. | Keeps the batch and retries with backoff. |

## Proposals

These fill gaps in v1. KestrelKit already behaves as described; the server can rely on that, and
should say so here if it wants something else.

**P1. Characters are Unicode scalar values.** All "characters" limits count Unicode scalar values
(Rust's `char`), not bytes and not grapheme clusters. KestrelKit truncates to whole grapheme
clusters within that count, so it never sends half an emoji.

**P2. The 256 KB limit is for the uncompressed body.** KestrelKit keeps the JSON at or under
262,144 bytes before gzip. The server should cap the decompressed size at the same value (and
answer `413` above it), which also protects it from gzip bombs.

**P3. gzip only when it helps.** KestrelKit compresses bodies of 1 KB or more, and only sends the
compressed form when it is smaller. `gzip` is the only `Content-Encoding` it uses.

**P4. Limits for the other strings.** `bundle_id`, `version`, `build`, `os_version`, `model` and
`locale` are at most 200 characters each, without control characters. KestrelKit trims and cuts
them. `install_id` and `session_id` are opaque strings of at most 64 characters (KestrelKit sends
upper-case UUIDs, 36 characters).

**P5. Lenient per signal, strict per batch.** The server answers `400` only when the body isn't
JSON or doesn't have the shape above. A single signal that breaks a limit is fixed (cut) or skipped
on its own, and `accepted` counts the signals that were stored. KestrelKit treats any `2xx` as done,
whatever `n` is, so it never resends a batch the server has seen.

**P6. Missing or unknown fields.** A missing `payload` means `{}`; missing `flags` mean `false`.
Unknown fields are ignored, so SDKs can add fields without breaking older servers. An unknown
`platform` value is stored as given (or as `other`), not rejected.

**P7. More status codes.**
- `404` means the server has no app-signal ingest (an older Kestrel). KestrelKit handles it like
  `401`/`403`: it stops until the next launch and keeps its queue, so the signals arrive after the
  server is upgraded.
- `408` is retried like a `5xx`.
- Any other `4xx` is handled like `400`.
- Any `2xx` counts as accepted.

**P8. Retry-After.** KestrelKit reads `Retry-After` as a number of seconds; an HTTP date falls back to
exponential backoff. It never waits longer than 1 hour, whatever the header says. Exponential
backoff starts at 30 seconds and doubles up to 1 hour, with up to 20 % jitter; a success resets it.

**P9. Reserved signal types.** KestrelKit sends two signals by itself (an app can turn them off):
- `App.launched` when the app starts (the first signal of a new session).
- `Session.started` when a new session starts after the app was in the background for 5 minutes
  or more.

The server can count sessions as distinct `session_id` values; these two signals make sure every
session has at least one signal. Types starting with `App.`, `Session.` or `Kestrel.` are reserved
for SDKs.

**P10. Clock skew.** The server corrects `time` by `server_now − sent_at` when the difference is
more than a few seconds, then clamps times in the future to `server_now`. Signals older than the
raw-signal retention (30 days) after correction can be dropped.

**P11. Duplicates (later, v1.1).** If a response is lost after the server stored a batch, the SDK
sends it again. That is rare and harmless for trends, so v1 accepts it. A later version could add an
optional `batch_id` (UUID) to the body so the server can ignore a batch it has already stored.
KestrelKit doesn't send one yet.

**P12. Request headers.** KestrelKit sends `User-Agent: KestrelKit/<version>`. The server doesn't need
it and, as for web analytics, shouldn't store it. No cookies are sent or accepted.

**P13. Scrubbing on both sides.** KestrelKit replaces payload values that look like an email address,
a phone number, a card number (Luhn-checked) or a `Bearer`/`Basic` credential with `[Filtered]`,
using the same rules as the server's `src/analytics/clean.rs`. The server scrubs again, so older
or other SDKs are covered too.
