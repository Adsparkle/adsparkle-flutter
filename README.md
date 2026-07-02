# adsparkle_flutter

Flutter client SDK for the **Viralif / AdBird** affiliate attribution tracking
platform. Pure Dart — **no platform channels**.

Mobile apps use this SDK to capture an attribution `click_id` from a deep link
and send affiliate attribution events (install, sign up, purchase, …) to the
tracking API.

## Installation

```sh
flutter pub add adsparkle_flutter
```

Or add to your app's `pubspec.yaml` manually:

```yaml
dependencies:
  adsparkle_flutter: ^0.1.3
```

Then:

```sh
flutter pub get
```

## Quick start

```dart
import 'package:adsparkle_flutter/adsparkle_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AdSparkle.instance.configure(
    companyKey: 'co_xxxxxxxxxxxxxxxx', // publishable key (see note below)
    baseUrl: 'https://api.adsparkle.co', // optional, this is the default
    debug: true,                       // verbose logs in debug builds
  );

  runApp(const MyApp());
}
```

## Identifying the user

Set the end-user identifier once you know it (e.g. after login). It is
persisted across launches.

```dart
await AdSparkle.instance.setUserId('user-123');
```

## Capturing the `click_id` from a deep link

The attribution `click_id` arrives as a deep link query parameter:

```
https://app.example.com/open?click_id=2f1c9b7e-...
```

Pass any incoming `Uri` to `handleDeepLink`; the SDK extracts, persists, and
chains the `click_id` (most-recent-last, de-duplicated, capped at 10).

### With `uni_links` / `app_links`

```dart
import 'package:app_links/app_links.dart';

final appLinks = AppLinks();

// Cold start
final initial = await appLinks.getInitialLink();
if (initial != null) {
  await AdSparkle.instance.handleDeepLink(initial);
}

// While running
appLinks.uriLinkStream.listen((uri) {
  AdSparkle.instance.handleDeepLink(uri);
});
```

### With `go_router`

```dart
GoRouter(
  redirect: (context, state) {
    AdSparkle.instance.handleDeepLink(state.uri);
    return null; // don't redirect; just harvest the click_id
  },
  routes: [...],
);
```

You can also set it manually if you obtain it another way:

```dart
await AdSparkle.instance.setClickId('2f1c9b7e-...');
```

## Tracking events

Use the typed helpers, or the generic `track(eventType, …)`:

```dart
await AdSparkle.instance.trackInstall();
await AdSparkle.instance.trackSignUp();
await AdSparkle.instance.trackLogin();
await AdSparkle.instance.trackDownload();

await AdSparkle.instance.trackPurchase(
  transactionId: 'txn_001',
  amount: 9.99,
  currency: 'USD',
  productIds: ['premium_monthly'],
  customParams: {'campaign': 'summer'},
);

await AdSparkle.instance.trackSubscription(
  transactionId: 'sub_001',
  amount: 49.99,
  currency: 'USD',
);

await AdSparkle.instance.trackRefund(transactionId: 'txn_001');

// Generic form:
await AdSparkle.instance.track(
  'purchase',
  transactionId: 'txn_002',
  amount: 4.50,
  currency: 'EUR',
);
```

If there is no `click_id` or no `user_id` available, `track` quietly skips the
event (a debug log is emitted when `debug: true`) — it never throws.

## Event types

| Event          | Wire value     | Helper               | Required extra fields            |
| -------------- | -------------- | -------------------- | -------------------------------- |
| Install        | `install`      | `trackInstall`       | —                                |
| Sign up        | `sign_up`      | `trackSignUp`        | —                                |
| Login          | `login`        | `trackLogin`         | —                                |
| Download       | `download`     | `trackDownload`      | —                                |
| Purchase       | `purchase`     | `trackPurchase`      | `transactionId`, `amount`        |
| Subscription   | `subscription` | `trackSubscription`  | `transactionId`, `amount`        |
| Refund         | `refund`       | `trackRefund`        | `transactionId`                  |

Besides the built-ins above, a company **custom-event shortId** (e.g.
`YE2YFSQ`) can be passed directly as the `event_type`:

```dart
await AdSparkle.instance.track(
  'YE2YFSQ',
  productIds: ['premium_monthly'],
  customParams: {'campaign': 'summer'},
);
```

The value is validated against `^[A-Za-z0-9_]{1,64}$` (mixed case — shortIds
are uppercase, built-in keys lowercase) and sent as-is on the wire; values that
fail this format check are ignored. `product_ids` and `custom_params` are
already supported by `track` (and the typed helpers) for every event type.

## Reliability

- Postbacks go to `POST {baseUrl}/api/tracking/postback`.
- On `5xx` responses or network errors the SDK retries up to **3 times** with
  exponential backoff.
- If all attempts fail, the event is saved to a **persisted pending queue**
  (`shared_preferences`) and re-sent on the next `track()` / `configure()`.
- `4xx` responses are treated as permanent and the event is dropped.

## Security note — the company key is *publishable*

`companyKey` is a **publishable** `co_` key. It is safe to ship inside your app
binary. It is **not** a secret. This SDK never uses an HMAC secret and never
signs requests — secret-based signing happens server-side only.

## Reading the current click id

```dart
final id = AdSparkle.instance.clickId; // String?
```
