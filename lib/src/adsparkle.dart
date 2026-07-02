import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'adsparkle_event.dart';
import 'deeplink.dart';
import 'postback_client.dart';
import 'storage.dart';

/// Default tracking API base URL.
const String _kDefaultBaseUrl = 'https://api.adsparkle.co';

/// Maximum number of click ids retained in the attribution chain.
const int _kMaxClickIds = 50;

/// Attribution window for the click chain: 7 days, expressed in milliseconds.
/// This is a *sliding* window — every new click id resets it. When reading the
/// chain, if more than this has elapsed since the last update, the chain is
/// treated as empty and cleared.
const int _kChainTtlMs = 7 * 24 * 60 * 60 * 1000; // 604800000

/// Maximum number of events retained in the offline retry queue. When the cap
/// is exceeded the oldest event is dropped.
const int _kMaxQueueSize = 100;

/// AdSparkle — the Flutter client SDK for the Viralif/AdBird affiliate
/// attribution tracking platform.
///
/// Access the SDK through the [instance] singleton:
///
/// ```dart
/// await AdSparkle.instance.configure(companyKey: 'co_xxx');
/// await AdSparkle.instance.setUserId('user-123');
/// await AdSparkle.instance.handleDeepLink(uri);
/// await AdSparkle.instance.trackPurchase(
///   transactionId: 'txn_1', amount: 9.99, currency: 'USD');
/// ```
///
/// The SDK is pure Dart — there are no platform channels. The [companyKey] is
/// a *publishable* `co_` key, not a secret; no HMAC secret is ever used.
class AdSparkle {
  AdSparkle._({
    AdSparkleStorage? storage,
    PostbackClient? client,
  })  : _storage = storage ?? AdSparkleStorage(),
        _clientOverride = client;

  /// The shared SDK instance.
  static final AdSparkle instance = AdSparkle._();

  /// Creates an isolated instance for testing with injected dependencies.
  @visibleForTesting
  factory AdSparkle.forTesting({
    AdSparkleStorage? storage,
    PostbackClient? client,
  }) =>
      AdSparkle._(storage: storage, client: client);

  final AdSparkleStorage _storage;
  final PostbackClient? _clientOverride;
  PostbackClient? _client;

  bool _configured = false;
  bool _debug = false;
  String? _companyKey;
  String _baseUrl = _kDefaultBaseUrl;
  String? _userId;
  String? _clickId;

  /// Guards against concurrent flushes of the pending queue.
  Future<void>? _flushing;

  /// The current attribution click id, if any.
  String? get clickId => _clickId;

  PostbackClient get _postback {
    return _clientOverride ??
        (_client ??= PostbackClient(
          logger: _debug ? (m) => _log(m) : null,
        ));
  }

  /// Configures the SDK. Must be called once (typically at app startup) before
  /// tracking events.
  ///
  /// Persisted state from a previous session (user id, click id, click chain,
  /// pending queue) is restored. Any events that failed to send previously are
  /// flushed.
  Future<void> configure({
    required String companyKey,
    String baseUrl = _kDefaultBaseUrl,
    bool debug = false,
  }) async {
    _debug = debug;
    _companyKey = companyKey;
    _baseUrl = baseUrl;

    await _storage.setCompanyKey(companyKey);
    await _storage.setBaseUrl(baseUrl);

    // Restore previously persisted attribution state.
    _userId = await _storage.getUserId();
    _clickId = await _storage.getClickId();
    await _loadChain(); // TTL/expiry yan etkisi icin cagrilir (sonuc cache'lenmez)

    _configured = true;
    _log('configured (baseUrl=$baseUrl, userId=$_userId, clickId=$_clickId)');

    await _flushPending();
  }

  /// Sets and persists the current end-user identifier.
  Future<void> setUserId(String userId) async {
    _userId = userId;
    await _storage.setUserId(userId);
    _log('userId set to $userId');
    await _flushPending();
  }

  /// Sets and persists the current attribution [clickId], also appending it to
  /// the click chain.
  Future<void> setClickId(String clickId) async {
    await _persistClickId(clickId);
    _log('clickId set to $clickId');
  }

  /// Extracts a `click_id` from [uri]'s query parameters and persists it.
  ///
  /// Wire this up to your deep link handler (e.g. `uni_links`, `app_links`, or
  /// a `go_router` redirect). No-op if the URI carries no `click_id`.
  Future<void> handleDeepLink(Uri uri) async {
    final extracted = DeepLinkParser.extractClickId(uri);
    if (extracted == null) {
      _log('handleDeepLink: no click_id in $uri');
      return;
    }
    await _persistClickId(extracted);
    _log('handleDeepLink: click_id=$extracted');
  }

  /// Tracks an attribution event by its string [eventType].
  ///
  /// [eventType] may be a built-in type (`install`, `sign_up`, `login`,
  /// `download`, `purchase`, `subscription`, `refund`) or a company
  /// custom-event shortId (e.g. `YE2YFSQ`). It is validated against
  /// `^[A-Za-z0-9_]{1,64}$` and sent as-is on the wire; values that fail this
  /// format check are ignored (with a debug log) and never throw.
  ///
  /// If no [clickId] or user id is available, the call is skipped without an
  /// exception.
  Future<void> track(
    String eventType, {
    String? transactionId,
    num? amount,
    String? currency,
    List<String>? productIds,
    Map<String, String>? customParams,
  }) async {
    if (!_isValidEventType(eventType)) {
      _log('track: invalid event_type "$eventType" — ignored');
      return;
    }
    await _trackEvent(
      eventType,
      transactionId: transactionId,
      amount: amount,
      currency: currency,
      productIds: productIds,
      customParams: customParams,
    );
  }

  /// Tracks an `install` event.
  Future<void> trackInstall({Map<String, String>? customParams}) =>
      _trackEvent(AdSparkleEventType.install.wireName,
          customParams: customParams);

  /// Tracks a `sign_up` event.
  Future<void> trackSignUp({Map<String, String>? customParams}) =>
      _trackEvent(AdSparkleEventType.signUp.wireName,
          customParams: customParams);

  /// Tracks a `login` event.
  Future<void> trackLogin({Map<String, String>? customParams}) =>
      _trackEvent(AdSparkleEventType.login.wireName,
          customParams: customParams);

  /// Tracks a `download` event.
  Future<void> trackDownload({Map<String, String>? customParams}) =>
      _trackEvent(AdSparkleEventType.download.wireName,
          customParams: customParams);

  /// Tracks a `purchase` event.
  Future<void> trackPurchase({
    required String transactionId,
    required num amount,
    String? currency,
    List<String>? productIds,
    Map<String, String>? customParams,
  }) =>
      _trackEvent(
        AdSparkleEventType.purchase.wireName,
        transactionId: transactionId,
        amount: amount,
        currency: currency,
        productIds: productIds,
        customParams: customParams,
      );

  /// Tracks a `subscription` event.
  Future<void> trackSubscription({
    required String transactionId,
    required num amount,
    String? currency,
    List<String>? productIds,
    Map<String, String>? customParams,
  }) =>
      _trackEvent(
        AdSparkleEventType.subscription.wireName,
        transactionId: transactionId,
        amount: amount,
        currency: currency,
        productIds: productIds,
        customParams: customParams,
      );

  /// Tracks a `refund` event.
  Future<void> trackRefund({
    required String transactionId,
    String? currency,
    List<String>? productIds,
    Map<String, String>? customParams,
  }) =>
      _trackEvent(
        AdSparkleEventType.refund.wireName,
        transactionId: transactionId,
        currency: currency,
        productIds: productIds,
        customParams: customParams,
      );

  /// Adjust-style otomatik ürün yakalama.
  ///
  /// `in_app_purchase` paketinin `PurchaseDetails` objesinden ürün kimliğini
  /// (ve transaction id'sini) KENDİLİĞİNDEN okur; merchant SKU'yu elle yazmak
  /// zorunda kalmaz. `in_app_purchase`'a bağımlılık YOKTUR — alanlar dinamik
  /// olarak okunur. Web SDK'daki dataLayer otomatik yakalamanın mobil karşılığı.
  ///
  /// `amount` `PurchaseDetails`'te bulunmadığı için yüzde komisyonlu event'lerde
  /// merchant tarafından geçilmelidir.
  Future<void> trackPurchaseFromStore(
    dynamic purchaseDetails, {
    required num amount,
    String? currency,
    Map<String, String>? customParams,
  }) {
    final ids = _extractStoreProductIds(purchaseDetails);
    final txId = _extractStoreTransactionId(purchaseDetails);
    return trackPurchase(
      transactionId: txId ?? '',
      amount: amount,
      currency: currency,
      productIds: ids.isEmpty ? null : ids,
      customParams: customParams,
    );
  }

  static List<String> _extractStoreProductIds(dynamic p) {
    try {
      final id = p?.productID;
      if (id is String && id.isNotEmpty) return <String>[id];
    } catch (_) {/* alan yok — boş dön */}
    return const <String>[];
  }

  static String? _extractStoreTransactionId(dynamic p) {
    try {
      final id = p?.purchaseID;
      if (id is String && id.isNotEmpty) return id;
    } catch (_) {/* alan yok — null dön */}
    return null;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<void> _trackEvent(
    String eventType, {
    String? transactionId,
    num? amount,
    String? currency,
    List<String>? productIds,
    Map<String, String>? customParams,
  }) async {
    if (!_configured) {
      _log('track: SDK not configured — call configure() first; skipping');
      return;
    }

    // Re-read the chain so the 7-day sliding window is enforced at conversion
    // time (a chain that expired since configure() is treated as empty).
    final chain = await _loadChain();
    final clickId = chain.isNotEmpty ? chain.last : null;
    if (clickId == null || clickId.isEmpty) {
      _log('track($eventType): no click_id — skipping');
      return;
    }

    // user_id is required by the backend; if the merchant never set one, fall
    // back to a persistent anonymous identifier so conversions are not lost.
    final userId = await _getOrCreateAnonUserId();

    final event = AdSparkleEvent(
      clickId: clickId,
      clickIds: chain.isEmpty ? null : List<String>.of(chain),
      eventType: eventType,
      userId: userId,
      transactionId: transactionId,
      amount: amount,
      currency: currency,
      productIds: productIds,
      customParams: customParams,
    );

    // Try to flush anything queued first so events are delivered in order.
    await _flushPending();

    final outcome = await _postback.send(
      baseUrl: _baseUrl,
      companyKey: _companyKey!,
      body: event.toJson(),
    );

    switch (outcome) {
      case PostbackOutcome.success:
        _log('track($eventType): delivered');
        break;
      case PostbackOutcome.retryable:
        _log('track($eventType): failed — queued for retry');
        await _enqueue(event.toJson());
        break;
      case PostbackOutcome.permanent:
        _log('track($eventType): dropped (permanent failure)');
        break;
    }
  }

  /// Validates a raw `event_type` wire value. Accepts both built-in types and
  /// company custom-event shortIds; matches the backend's `^[a-zA-Z0-9_]+$`
  /// (1-64 chars). Mixed case on purpose — shortIds are uppercase (e.g.
  /// `YE2YFSQ`), built-in keys lowercase (e.g. `purchase`).
  static bool _isValidEventType(String eventType) {
    return RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(eventType);
  }

  Future<void> _persistClickId(String clickId) async {
    // Reject anything that is not a well-formed UUID (silent, per spec).
    if (!DeepLinkParser.isValidClickId(clickId)) {
      _log('persistClickId: invalid click_id "$clickId" — ignored');
      return;
    }

    // Start from the (TTL-checked) current chain so an expired chain is reset
    // before this fresh click id is appended.
    final current = await _loadChain();

    _clickId = clickId;
    await _storage.setClickId(clickId);

    // Maintain a de-duplicated, most-recent-last chain capped at _kMaxClickIds.
    final chain = List<String>.of(current)..remove(clickId);
    chain.add(clickId);
    while (chain.length > _kMaxClickIds) {
      chain.removeAt(0);
    }
    await _storage.setClickIds(chain);
    // Sliding window: reset the TTL on every new click id.
    await _storage.setClickIdsTs(DateTime.now().millisecondsSinceEpoch);
  }

  /// Loads the persisted click chain, enforcing the 7-day sliding window. If
  /// the chain has not been updated within [_kChainTtlMs] it is treated as
  /// empty and the persisted copy (plus the single `click_id`) is cleared.
  Future<List<String>> _loadChain() async {
    final chain = await _storage.getClickIds();
    if (chain.isEmpty) return <String>[];

    final ts = await _storage.getClickIdsTs();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (ts == null || now - ts > _kChainTtlMs) {
      _log('click chain expired (ttl) — clearing');
      await _storage.clearClickIds();
      _clickId = null;
      return <String>[];
    }

    _clickId = chain.last;
    return chain;
  }

  /// Returns the current user id, generating and persisting a stable anonymous
  /// identifier the first time one is needed. Mirrors the web SDK's
  /// `getOrCreateAnonId`: `anon_<base36(ms)><8 base36 random chars>`.
  Future<String> _getOrCreateAnonUserId() async {
    final existing = _userId;
    if (existing != null && existing.isNotEmpty) return existing;

    final ms = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = _randomBase36(8);
    final anon = 'anon_$ms$rand';
    _userId = anon;
    await _storage.setUserId(anon);
    _log('generated anonymous user_id $anon');
    return anon;
  }

  /// Generates [length] random base-36 characters (0-9, a-z).
  static String _randomBase36(int length) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    final rand = Random();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(chars[rand.nextInt(chars.length)]);
    }
    return buffer.toString();
  }

  Future<void> _enqueue(Map<String, dynamic> body) async {
    final queue = await _storage.getPendingQueue();
    queue.add(body);
    // Cap the offline queue; drop the oldest event(s) when over capacity.
    while (queue.length > _kMaxQueueSize) {
      queue.removeAt(0);
    }
    await _storage.setPendingQueue(queue);
  }

  /// Attempts to deliver every queued event. Successfully delivered (or
  /// permanently failed) events are removed; retryable events stay queued.
  Future<void> _flushPending() {
    // Collapse concurrent invocations into a single in-flight flush.
    return _flushing ??= _doFlush().whenComplete(() => _flushing = null);
  }

  Future<void> _doFlush() async {
    if (!_configured || _companyKey == null) return;

    final queue = await _storage.getPendingQueue();
    if (queue.isEmpty) return;

    final remaining = <Map<String, dynamic>>[];
    for (final body in queue) {
      final outcome = await _postback.send(
        baseUrl: _baseUrl,
        companyKey: _companyKey!,
        body: body,
      );
      if (outcome == PostbackOutcome.retryable) {
        // Keep this and all subsequent events to preserve ordering.
        remaining.add(body);
      }
      // success / permanent → drop.
    }

    if (remaining.length != queue.length) {
      await _storage.setPendingQueue(remaining);
      _log('flushed pending queue (${queue.length - remaining.length} sent, '
          '${remaining.length} remaining)');
    }
  }

  void _log(String message) {
    if (_debug) {
      debugPrint('[AdSparkle] $message');
    }
  }
}
