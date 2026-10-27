# Security review, October 2026

Date: 27 October 2026. Covers the KestrelKit Swift SDK up to the 0.1.1 release. The matching server-side review is in
the Keen Kestrel repository.

## Method and limits

This was a read-only code review done by an AI reviewer, as a privacy and transport review of the SDK. It was not an
external audit and it was not done by a professional security firm. The reviewer read the code and rated each
finding; the fixes were written with tests and merged after review. Nothing was run on a device: there was no
dynamic testing and no fuzzing. Tests ran on Linux (Swift 6.2) in CI; one redirect test only runs on Apple
platforms, where the macOS CI job covers it.

Treat this as one careful review, not as a guarantee.

## Scope

`main` at `591625a`: the whole SDK, including the engine and flush loop, the persistent queue, scrubbing and limits,
the transport, identifiers and opt-out. No High finding was reported.

Found solid: random install and session ids that are deleted on opt-out, no IDFA or IDFV, queue bounds, handling of
`Retry-After`, the project key sent only in a header, cookies and cache off for the SDK's requests, and no
third-party dependencies.

## Findings

| ID | Severity | Title | Status |
|---|---|---|---|
| KS-01 | Low | Opt-out not immediate for an in-flight flush | Fixed in #10 |
| KS-02 | Low | Scrubbing ran before control characters were removed, so they could split emails and card numbers past the patterns | Fixed in #10 (SDK) and in Keen Kestrel #45 (server) |
| KS-03 | Low | Scrubber missed compressed IPv6 and cards separated by dots or non-breaking spaces; payload keys such as `password` or `token` were not dropped | Fixed in #10 (SDK). Server side: sensitive keys dropped in Keen Kestrel #45; the IPv6 and card patterns are not added on the server. Open |
| KS-04 | Low | Quadratic regex time on long values | Fixed in #10 |
| KS-05 | Low | No transport policy (http allowed, redirects followed with the key header, unbounded response, 7-day resource timeout) | Fixed in #10 |
| KS-06 | Low | Unbounded command stream; a full queue rewrote up to 5 MB per signal | Fixed in #10 |
| KS-07 | Low | Any 2xx counted as delivered; some 4xx dropped batches; 401, 403 and 404 silenced the SDK until relaunch | Fixed in #10 |
| KS-08 | Info | Sharp edges | Open, not changed |

### What was changed

- The flush loop checks the opt-out before every batch and after every upload, and cancels an upload in flight.
- Control characters are removed before scrubbing. Compressed IPv6 addresses and card numbers separated by dots or
  non-breaking spaces are scrubbed. Payload keys containing `pass`, `secret`, `token`, `auth`, `key`, `card`,
  `cookie`, `cvv`, or `ssn` as a word, are dropped with their values. Values are cut to 2000 characters before
  scrubbing, and the email and `name=value` patterns have bounded runs.
- `http://` is refused except for `localhost` and debug builds. Redirects are not followed, answers over 64 KB are
  ignored, and the resource timeout is 60 seconds.
- Only a `202` with `{"accepted": n}` counts as delivered. Other 2xx, 3xx, 405, 407, 408 and 410 answers keep the
  batch and retry with backoff. 401, 403 and 404 pause sending for an hour instead of until relaunch.
- The command stream is bounded to 1000 (oldest dropped, an opt-out is never lost). A full queue file is appended to
  and compacted after a batch of drops instead of being rewritten per signal.

## Accepted and open items

- **KS-08, sharp edges, open.** Calling `description()` on arbitrary objects, debug builds sending to production, and the install id in `UserDefaults` surviving a device restore. These are
  informational and were not changed.
- **Server-side IPv6 and card patterns (KS-03), open.** Shortened IPv6 addresses and dotted or non-breaking-space
  card groupings are scrubbed on the device only. A modified or older client can still send them, and the Keen
  Kestrel server does not scrub them.
- **Scrubbing is best effort.** It is pattern-based and cannot recognise every kind of personal data. Do not put
  personal data in signal payloads.

## Not covered

- Dynamic behaviour on devices: nothing was run on iOS, macOS or watchOS hardware, and no network capture was done.
- The Keen Kestrel server, which is reviewed in its own repository.
- CI workflows and the release pipeline, and the documentation site.

## Notes for app developers

Release notes: [0.1.1](https://github.com/Ferdinand99/KestrelKit/releases/tag/v0.1.1).

- Payload keys that contain `key`, `auth`, `pass` and the other words above (for example `keyboard_layout` or
  `author`) are now dropped.
- `http://` endpoints stop working in release builds except for `localhost`.
- A wrong project key no longer silences the SDK until relaunch; it retries after an hour.
- Delivery now requires a `202` answer from the server.
