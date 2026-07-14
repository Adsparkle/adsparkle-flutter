# Changelog

## 0.1.5

- `configure()` now accepts an optional `linkDomainSuffix` (default
  `.go.adsparkle.co`) so test/prod deployments can use different link domains,
  mirroring the backend `LINK_DOMAIN_SUFFIX` env. Existing calls are unchanged.
- Deferred attribution: Play Install Referrer capture, probabilistic `/match`,
  and register-click for app-installed universal-link opens.

## 0.1.4

- Rebrand: package description, docs and license now reference **AdSparkle**
  (formerly "Viralif / AdBird"). No code changes.

## 0.1.3

- Accept company custom-event shortIds (e.g. `YE2YFSQ`) as `eventType` — the
  fixed 7-event allowlist was relaxed to the backend format
  `^[A-Za-z0-9_]{1,64}$`. Built-in typed helpers are unchanged.
- `AdSparkleEvent.eventType` is now the raw wire string, so queued custom
  events survive persistence and offline replay.
- Documented `productIds` / `customParams` support (product-scoped campaigns).

## 0.1.2

- Default API base URL is now `https://api.adsparkle.co` (was `api.viralif.co`).
- Aligned with the Web/RN/Android/iOS SDK family.


## 0.1.0

Initial release.

- Singleton `AdSparkle.instance` public API.
- `configure()`, `setUserId()`, `setClickId()`, `handleDeepLink()`.
- `track()` plus typed helpers: `trackInstall`, `trackSignUp`, `trackLogin`,
  `trackDownload`, `trackPurchase`, `trackSubscription`, `trackRefund`.
- Deep link `click_id` extraction from URI query parameters.
- Click chain persistence (de-duplicated, max 10 entries).
- Postback delivery to `POST {baseUrl}/api/tracking/postback` with
  `X-Company-Key` auth (publishable `co_` key; no secret/HMAC).
- Exponential backoff retry (3 attempts) on 5xx / network errors.
- Persisted pending queue (`shared_preferences`) flushed on the next
  `configure()` / `track()`.
