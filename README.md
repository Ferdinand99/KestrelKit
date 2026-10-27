<p align="center">
  <img src="https://raw.githubusercontent.com/Ferdinand99/Keen-Kestrel/main/assets/brand/kestrel-icon.svg" alt="" width="128">
</p>

<h1 align="center">KestrelKit</h1>

<p align="center"><strong>Privacy-friendly app analytics for iOS and macOS, sent to your own Keen Kestrel.</strong></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-lightgrey.svg" alt="Platforms">
</p>

> **Status: early.** KestrelKit works and is tested. It needs Keen Kestrel v0.2 or later, the first
> version with app analytics. The API may still change before 1.0.

KestrelKit is a small Swift package that tells you how your app is used, without telling you who uses
it. Your app sends **signals**, such as `Paywall.shown` or `Export.finished`. KestrelKit queues them on
the device and sends them in batches to [Keen Kestrel](https://github.com/Ferdinand99/Keen-Kestrel),
the self-hosted error tracker and analytics tool. Kestrel turns them into dashboards: users, sessions,
signals over time, versions, devices and locales.

- No IDFA, no IDFV, no fingerprinting, no cookies. Kestrel never stores IP addresses.
- Swift 6 with strict concurrency, no dependencies, a privacy manifest included.
- Works offline: signals wait on disk and go out when the network is back.

## Install

In Xcode, choose **File › Add Package Dependencies…** and enter:

```
https://github.com/Ferdinand99/KestrelKit
```

Or add it to `Package.swift`:

```swift
.package(url: "https://github.com/Ferdinand99/KestrelKit", from: "0.1.0")
```

KestrelKit supports iOS 15, macOS 12, tvOS 15, watchOS 9 and visionOS 1 or later.

## Quick start

```swift
import KestrelKit

Kestrel.configure(url: URL(string: "https://kestrel.example.com")!, key: "<project key>")
Kestrel.signal("Paywall.shown", payload: ["plan": "pro"])
Kestrel.signal("Export.finished", payload: ["pages": 12, "pdf": true])
```

The key is the project's public key: the 32 hex characters at the start of the project's DSN
(`https://<key>@kestrel.example.com/1`), on the project's settings page in Kestrel. It's the same key
the Sentry SDK uses, so one project gets both errors and analytics.

KestrelKit only talks to `https://` addresses. `http://` works for `localhost`, and in debug builds
for any host (a Kestrel on your own network); in a release build any other `http://` address is
refused and nothing is stored or sent.

### SwiftUI

```swift
import SwiftUI
import KestrelKit

@main
struct MyApp: App {
    init() {
        Kestrel.configure(
            url: URL(string: "https://kestrel.example.com")!,
            key: "0123456789abcdef0123456789abcdef",
            configuration: .init(defaultPayload: ["theme": "dark"])
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct PaywallView: View {
    var body: some View {
        Text("Go Pro")
            .onAppear { Kestrel.signal("Paywall.shown") }
    }
}
```

Every call returns at once and is safe from any thread. Signals are sent every 30 seconds and when
the app moves to the background. `await Kestrel.flush()` sends them right away.

### Options

`Kestrel.Configuration` has these options; the defaults suit most apps.

| Option | Default | What it does |
|---|---|---|
| `debugSignals` | `.flag` | Signals from debug builds are sent with `flags.debug` set, and Kestrel leaves them out of its dashboards unless you include test signals. `.drop` keeps them on the device instead. |
| `testMode` | `nil` | `true` treats every signal as a test signal (UI tests, internal builds); `false` never does. `nil` follows the build. |
| `flushInterval` | `30` | Seconds between sends. |
| `defaultPayload` | `[:]` | Added to every signal; a signal's own keys win. |
| `automaticSignals` | `true` | Sends `App.launched` and `Session.started`. |
| `maxQueuedSignals` | `5000` | The most signals kept offline; the oldest go first. |

## What is collected

Each signal has:

- its **type** and **payload** (what your app passes), and the time it happened;
- a random **install id**: a UUID that KestrelKit creates once and keeps in your app's own defaults.
  Kestrel stores only a keyed hash of it. It's gone when the app is deleted or the user opts out;
- a **session id**: a new random UUID at launch and after 5 minutes or more in the background;
- the app's **bundle id, version and build**;
- the **platform, OS version, hardware model** (such as `iPhone16,2`) and **locale** (such as `nb_NO`);
- three **flags**: debug build, TestFlight, simulator.

**Never collected:** the IDFA or IDFV, the device name, the user's name or email, location, contacts,
IP addresses (Kestrel doesn't store them), or anything to fingerprint a device.

Payloads are filtered on the device, with the same rules Kestrel applies again on the server (the
shortened IPv6 forms and the dot and non-breaking-space card groupings below are only caught on the
device for now). Control characters are removed first, and a value is cut to 2,000 characters before
it is filtered, so a very long value is cheap:

- values that look like an email address, a phone number, a card number (13 to 19 digits grouped by
  spaces, dashes, dots or non-breaking spaces, and passing the Luhn check), an IP address (IPv4, and
  IPv6 written out or shortened with `::`, such as `2001:db8::1` and `::1`), a `Bearer`/`Basic`
  credential or a `token=…`-style secret are replaced by `[Filtered]`;
- keys that name an IP address or a user agent (`ip`, `client_ip`, `x-forwarded-for`, `user_agent`
  and the like) are dropped with their values;
- keys that look like they hold a secret are dropped with their values: any key containing `pass`
  (`password`, `passwd`), `secret`, `token`, `auth`, `key`, `card`, `cookie` or `cvv`, and `ssn` as a
  word of its own, ignoring case. This is blunt on purpose: `keyboard_layout` and `author` go too, so
  give such keys other names (`layout`, `writer`).

Payloads are limited to 20 keys of up to 40 characters, with values of up to 200 characters. Keep
personal data out of them; the filtering is a safety net, not a licence.

Signal types use `A–Z a–z 0–9 . _ -`; KestrelKit turns other characters into `_`
(`Paywall shown` becomes `Paywall_shown`), because Kestrel drops signals with any other type.

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) that declares no tracking, product
interaction and a device id (the install id) collected for analytics and not linked to the user,
and `UserDefaults` access for the app's own data (reason `CA92.1`). In App Store Connect, the matching
answers are **Product Interaction** and **Device ID**, used for **Analytics**, **not linked** to the
user and **not used for tracking**.

## Opting out

Give your users a switch:

```swift
Toggle("Share anonymous usage data", isOn: Binding(
    get: { Kestrel.isEnabled },
    set: { Kestrel.isEnabled = $0 }
))
```

When `Kestrel.isEnabled` is `false`, nothing is stored or sent. Turning it off deletes the queued
signals and the install id; turning it back on starts with a new install id. KestrelKit remembers the
choice across launches. Nothing is sent before `Kestrel.configure` is called either.

## How it works

- Signals are written to a small queue file in Application Support (excluded from backups), so they
  survive restarts and offline periods. Each batch holds up to 100 signals or 256 KB, and is
  gzipped when that makes it smaller.
- When the server is busy or unreachable, KestrelKit backs off: from 30 seconds up to an hour, or as
  long as the server's `Retry-After` says. A wrong or disabled key (or a server without app
  analytics) pauses sending for an hour. Only Keen Kestrel's own answer (`202` with `{"accepted": n}`)
  counts as delivered; any other answer, a captive portal's `200` for example, keeps the batch and
  retries with backoff.
- Redirects are never followed, answers bigger than 64 KB are ignored, and a request gets 60 seconds
  at most.
- Turning `Kestrel.isEnabled` off cancels an upload in progress and sends nothing more.
- Up to 1,000 calls can wait for the queue at once while it is busy; when more arrive, the oldest are
  dropped.
- On iOS, tvOS and visionOS, KestrelKit asks for a little background time to finish the upload when
  the app moves to the background. On the Mac, "background" means another app is active.
- TestFlight builds are recognised by their sandbox App Store receipt. This doesn't work for Mac
  TestFlight builds yet, so on the Mac `testflight` is always `false`.

The wire format is in [`docs/protocol.md`](docs/protocol.md).

## Development

```bash
swift build
swift test
```

The core builds and tests on Linux too; the parts that use UIKit, AppKit or WatchKit only build on
Apple platforms. CI runs the tests on Linux and macOS and builds for every Apple platform.

## License

[MIT](LICENSE). The SDK goes into your app, so it uses a permissive license: it can ship in any
app, closed-source and App Store apps included. The Keen Kestrel server is AGPL-3.0.
