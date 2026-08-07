# Changelog

## 0.1.6

- Deep-link `unique_key` is now the **last** non-empty path segment, matching
  the backend `/:appSlug?/:uniqueKey` route (multi-app `/slug/key` links;
  single-segment links are unchanged).
- Link-host acceptance now also matches the configured `baseUrl` host, plus an
  optional `configure(extraLinkHosts: [...])` list (equal or `.suffix` match,
  trimmed and lowercased). Existing `configure` calls are unchanged.
- Sticky click_id fix: an existing click_id no longer blocks register-click for
  a new link tap — the new id unconditionally becomes active and joins the
  chain. An expired (7-day TTL) chain now also clears the persisted scalar
  `click_id`.
- register-click failures are classified: 4xx (except 408/429) is permanent —
  the pending request is cleared (unblocking the Android Install Referrer
  fallback); 5xx/408/429/network errors keep it for retry. Pending is cleared
  with compare-and-clear so an in-flight response never wipes a newer tap, and
  an in-flight guard prevents duplicate register-click POSTs.
- `track()` retries a pending register-click even when a click_id already
  exists.
- Postbacks now treat HTTP 408/429 as retryable (queued) instead of permanent.

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
