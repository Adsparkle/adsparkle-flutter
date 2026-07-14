import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'adsparkle_event.dart';
import 'deeplink.dart';
import 'install_referrer.dart';
import 'match_client.dart';
import 'postback_client.dart';
import 'register_client.dart';
import 'storage.dart';

/// ADIM 5: Universal Link/App Links kok domain'i (<slug>.go.adsparkle.co). Hardcode.
/// handleDeepLink yalnizca bu suffix'li URL'lerde register-click cagirir; merchant'in
/// kendi deep-link'lerinde DEGIL. NOT: enterprise link domain gelirse bu kontrol kirilir.
const String _kLinkDomainSuffix = '.go.adsparkle.co';

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

/// AdSparkle — the Flutter client SDK for the AdSparkle affiliate
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
/// The [companyKey] is a *publishable* `co_` key, not a secret; no HMAC secret
/// is ever used. The only native code is an Android platform channel that reads
/// the Play Install Referrer for deterministic install attribution (see
/// [InstallReferrer]); every other platform runs pure Dart.

/// ADIM 4: SDK çalışma ortamı. [sandbox] → tüm giden isteklere (postback,
/// register-click, /match) `test: true` eklenir; backend ClickEvent/
/// InstallFingerprint YAZMAZ, postback yalnızca şekil-doğrulanır (ledger etkilenmez).
/// Varsayılan [production]. Storage'a BOOL olarak çözülür (enum serialize EDİLMEZ —
/// değer değişirse eski storage kırılmasın).
enum AdSparkleEnvironment { production, sandbox }

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
  /// ADIM 4: sandbox modu mu? true ise giden body'lere test:true eklenir.
  bool _isSandbox = false;
  String? _companyKey;
  String _baseUrl = _kDefaultBaseUrl;
  /// ADIM 5: link domain soneki (configure ile override edilebilir; test/prod farkli
  /// link domaini — backend LINK_DOMAIN_SUFFIX env'iyle esler). Varsayilan prod domaini.
  String _linkDomainSuffix = _kLinkDomainSuffix;
  String? _userId;
  String? _clickId;

  /// Guards against concurrent flushes of the pending queue.
  Future<void>? _flushing;

  /// In-memory guard so a double configure() in the same session does not read
  /// the Install Referrer twice (the persisted flag guards across launches).
  bool _referrerCheckedInSession = false;

  /// Ayni guard'in iOS /match karsiligi.
  bool _matchCheckedInSession = false;

  /// SDK'nin kalici cihaz UUID'si (iOS /match device_id) — bir kez uretilir.
  String? _deviceId;

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
    AdSparkleEnvironment environment = AdSparkleEnvironment.production,
    String linkDomainSuffix = _kLinkDomainSuffix,
  }) async {
    _debug = debug;
    _companyKey = companyKey;
    _baseUrl = baseUrl;
    // ADIM 5: bas nokta + lowercase normalize (host karsilastirmasi lowercase host + `.suffix`).
    final normSuffix = linkDomainSuffix.toLowerCase();
    _linkDomainSuffix = normSuffix.startsWith('.') ? normSuffix : '.$normSuffix';
    // ADIM 4: enum'u BOOL'a çöz (storage'a enum YAZMA — değeri değişirse eski
    // storage kırılmasın). Dart named param → sıra sorunu yok, mevcut çağrılar korunur.
    _isSandbox = environment == AdSparkleEnvironment.sandbox;

    await _storage.setCompanyKey(companyKey);
    await _storage.setBaseUrl(baseUrl);
    await _storage.setIsSandbox(_isSandbox);

    // Restore previously persisted attribution state.
    _userId = await _storage.getUserId();
    _clickId = await _storage.getClickId();
    await _loadChain(); // TTL/expiry yan etkisi icin cagrilir (sonuc cache'lenmez)

    _configured = true;
    _log('configured (baseUrl=$baseUrl, userId=$_userId, clickId=$_clickId)');

    await _flushPending();

    // Android deferred (install) attribution — Play Install Referrer.
    // iOS'un aksine Play Store referrer'i kurulumda tasir; ILK configure()'da
    // bir kez okunur ve click_id DETERMINISTIK kurtarilir. Non-blocking
    // (iOS MatchClient / native Android / RN ile paritede): configure()'i
    // geciktirmez — referrer cozulunce setClickId cagrilir. Zaten bir click_id
    // varsa (deep-link) hic denenmez. Native taraf yoksa/degilse null.
    if (_clickId == null &&
        !_referrerCheckedInSession &&
        !(await _storage.getReferrerChecked())) {
      _referrerCheckedInSession = true; // oturum-ici cift-okuma korumasi
      unawaited(InstallReferrer.readClickId().then((referrerClickId) async {
        if (referrerClickId != null && _clickId == null) {
          await setClickId(referrerClickId);
        }
        // Persist YALNIZCA okuma tamamlaninca — app okuma ortasinda oldurulurse
        // bir sonraki acilista tekrar denenir (native Android SDK'dan saglam).
        await _storage.setReferrerChecked(true);
      }));
    }

    // iOS deferred (probabilistic) attribution — POST /api/tracking/match.
    // Android'in aksine App Store referrer tasimaz; ILK configure()'da bir kez
    // (matchChecked) cihaz sinyalleri + kalici device_id yollanip son 60dk iOS
    // click'lerine eslestirilir. resolveMatch iOS-guard'li (Android/web → null).
    // Non-blocking (referrer/RN ile paritede): click_id cozulunce setClickId →
    // deferred kuyruk flush. device_id iOS guard'dan SONRA uretilir.
    // ADIM 5: bekleyen register-click (Universal Link/App Links, deep-link
    // deterministic) varsa /match'ten ONCE dene — deterministic olasilik-tabanliya
    // oncelikli (iOS/RN SDK ile ayni davranis).
    if (_clickId == null && (await _storage.getPendingRegisterClick()) != null) {
      unawaited(_attemptRegisterClick());
    } else if (_clickId == null &&
        !_matchCheckedInSession &&
        !(await _storage.getMatchChecked())) {
      _matchCheckedInSession = true; // oturum-ici cift-cagri korumasi
      unawaited(MatchClient.resolveMatch(
        baseUrl: _baseUrl,
        getDeviceId: _getOrCreateDeviceId,
        test: _isSandbox,
        log: _debug ? (m) => _log(m) : null,
      ).then((matchedClickId) async {
        if (matchedClickId != null && _clickId == null) {
          await setClickId(matchedClickId); // chain'e ekler + deferred flush
        }
        await _storage.setMatchChecked(true);
      }));
    }
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
    if (extracted != null) {
      await _persistClickId(extracted);
      _log('handleDeepLink: click_id=$extracted');
      return;
    }
    // ADIM 5 (E1): click_id yok VE URL bizim link domain'imizde → register-click
    // (app YUKLU acildi, sunucuya ugramadi). Merchant deep-link'inde HAYIR.
    if (!uri.host.toLowerCase().endsWith(_linkDomainSuffix)) {
      _log('handleDeepLink: no click_id in $uri');
      return;
    }
    // E2: unique_key = path'in ILK segmenti; query_params ayri.
    final uniqueKey = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
    if (uniqueKey.isEmpty) return;
    if (_clickId != null) return; // zaten click_id var
    await _storage.setPendingRegisterClick(<String, dynamic>{
      'unique_key': uniqueKey,
      'query_params': uri.queryParameters,
    });
    await _attemptRegisterClick();
  }

  /// Bekleyen register-click istegini dener (ADIM 5, E3). Basarida setClickId +
  /// pending temizlenir; basarisizsa (ag yok / 4xx / 5xx) pending KALIR —
  /// configure()/track()'te tekrar denenir. device_id = _getOrCreateDeviceId
  /// (/match ile AYNI kalici UUID).
  Future<void> _attemptRegisterClick() async {
    if (_clickId != null) return;
    final pending = await _storage.getPendingRegisterClick();
    if (pending == null) return;
    final uniqueKey = pending['unique_key'] as String?;
    if (uniqueKey == null || uniqueKey.isEmpty) return;
    final companyKey = _companyKey;
    if (companyKey == null || companyKey.isEmpty) return;
    final query = (pending['query_params'] as Map?)?.cast<String, String>() ??
        <String, String>{};
    final referrer = pending['referrer'] as String?;
    final deviceId = await _getOrCreateDeviceId();
    final clickId = await RegisterClient.resolve(
      baseUrl: _baseUrl,
      companyKey: companyKey,
      uniqueKey: uniqueKey,
      deviceId: deviceId,
      queryParams: query,
      referrer: referrer,
      test: _isSandbox,
      log: _debug ? (m) => _log(m) : null,
    );
    if (clickId != null && _clickId == null) {
      await _storage.setPendingRegisterClick(null);
      await setClickId(clickId); // → _persistClickId → _flushDeferred
    }
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
    // Q2 (ADIM 6a): flush'ta deferred event'in ENQUEUE-ANI sandbox flag'i geçirilir →
    // sandbox event, hangi env'de flush olursa olsun sandbox KALIR (dev/prod karışmaz).
    // Normal track'te null → güncel [_isSandbox]. Bu param PRIVATE (_trackEvent); public
    // API (trackInstall/trackPurchase...) değişmez.
    bool? testOverride,
  }) async {
    if (!_configured) {
      _log('track: SDK not configured — call configure() first; skipping');
      return;
    }

    final effectiveTest = testOverride ?? _isSandbox;

    // Re-read the chain so the 7-day sliding window is enforced at conversion
    // time (a chain that expired since configure() is treated as empty).
    final chain = await _loadChain();
    final clickId = chain.isNotEmpty ? chain.last : null;
    if (clickId == null || clickId.isEmpty) {
      // ADIM 5 (E3): bekleyen register-click varsa burada tekrar dene — basarida
      // click_id gelir ve deferred kuyruk flush olur.
      unawaited(_attemptRegisterClick());
      // Eskiden drop; artik DEFER — click_id (deep-link / Install Referrer / iOS
      // /match / register-click) gelince _flushDeferred bunlari gonderir
      // (install-oncesi track'ler kaybolmaz).
      await _enqueueDeferred(
        eventType,
        transactionId: transactionId,
        amount: amount,
        currency: currency,
        productIds: productIds,
        customParams: customParams,
        sandbox: effectiveTest, // Q2: enqueue-anı flag'i event'e GÖM
      );
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

    // ADIM 4: sandbox → şekil-doğrulama, ledger'a yazılmaz (HMAC bypass). Tek body
    // hem send hem retry-enqueue'da kullanılır (kuyruktaki de test:true olur). Q2:
    // effectiveTest (flush'ta stored flag, normal'de _isSandbox).
    final body = event.toJson();
    if (effectiveTest) body['test'] = true;

    final outcome = await _postback.send(
      baseUrl: _baseUrl,
      companyKey: _companyKey!,
      body: body,
    );

    switch (outcome) {
      case PostbackOutcome.success:
        _log('track($eventType): delivered');
        break;
      case PostbackOutcome.retryable:
        _log('track($eventType): failed — queued for retry');
        await _enqueue(body);
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

    // click_id artik var → bekleyen (deferred) olaylari gonder.
    await _flushDeferred();
  }

  // ---------------------------------------------------------------------------
  // Deferred events (click_id henuz yokken cagrilan track'ler)
  // ---------------------------------------------------------------------------

  Future<void> _enqueueDeferred(
    String eventType, {
    String? transactionId,
    num? amount,
    String? currency,
    List<String>? productIds,
    Map<String, String>? customParams,
    bool sandbox = false,
  }) async {
    final queue = await _storage.getDeferredEvents();
    queue.add(<String, dynamic>{
      'event_type': eventType,
      if (transactionId != null) 'transaction_id': transactionId,
      if (amount != null) 'amount': amount,
      if (currency != null) 'currency': currency,
      if (productIds != null) 'product_ids': productIds,
      if (customParams != null) 'custom_params': customParams,
      // Q2: enqueue-anı sandbox flag'i event'le KALICI saklanır (JSON round-trip);
      // flush'ta güncel state değil BU değer kullanılır → sandbox event sandbox kalır.
      if (sandbox) 'test': true,
    });
    while (queue.length > _kMaxQueueSize) {
      queue.removeAt(0); // FIFO cap
    }
    await _storage.setDeferredEvents(queue);
    _log('event "$eventType" deferred (queue: ${queue.length})');
  }

  /// click_id set edildikten SONRA cagrilir. Kuyruk once temizlenir (yeniden
  /// gonderim/yaris olmasin), sonra her biri _trackEvent ile gonderilir.
  Future<void> _flushDeferred() async {
    final queue = await _storage.getDeferredEvents();
    if (queue.isEmpty) return;
    await _storage.setDeferredEvents(<Map<String, dynamic>>[]);
    _log('flushing ${queue.length} deferred event(s)');
    for (final ev in queue) {
      final eventType = ev['event_type'];
      if (eventType is! String) continue;
      await _trackEvent(
        eventType,
        transactionId: ev['transaction_id'] as String?,
        amount: ev['amount'] as num?,
        currency: ev['currency'] as String?,
        productIds: (ev['product_ids'] as List?)?.cast<String>(),
        customParams: (ev['custom_params'] as Map?)?.cast<String, String>(),
        // Q2: enqueue-anında saklanan sandbox flag'i (güncel state DEĞİL) geçirilir.
        testOverride: ev['test'] as bool?,
      );
    }
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

  /// SDK'nin KALICI cihaz UUID'sini dondurur (iOS /match device_id). Yoksa bir
  /// kez uretir + saklar. Ayni cihaz her /match'te AYNI UUID → D2 tek-tuketim
  /// idempotency'si tutarli. anon_ userId'den AYRIDIR (IDFV DEGIL — Dart erisemez).
  Future<String> _getOrCreateDeviceId() async {
    final existing = _deviceId ?? await _storage.getDeviceId();
    if (existing != null && existing.isNotEmpty) {
      _deviceId = existing;
      return existing;
    }
    final id = _uuidv4();
    _deviceId = id;
    await _storage.setDeviceId(id);
    _log('generated persistent deviceId $id');
    return id;
  }

  /// RFC4122 v4 UUID (Random tabanli). Cihaz-id icin yeterli; backend `device_id`'yi
  /// UUID-regex ile dogruladigi icin FORMAT gecerli olmali.
  static String _uuidv4() {
    final rand = Random();
    String hex(int n) {
      final b = StringBuffer();
      for (var i = 0; i < n; i++) {
        b.write(rand.nextInt(16).toRadixString(16));
      }
      return b.toString();
    }

    final variant = (8 + rand.nextInt(4)).toRadixString(16); // 8,9,a,b
    return '${hex(8)}-${hex(4)}-4${hex(3)}-$variant${hex(3)}-${hex(12)}';
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
