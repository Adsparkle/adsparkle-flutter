import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper around [SharedPreferences] for persisting SDK state.
///
/// All keys are namespaced under `adsparkle.` to avoid clashing with the host
/// application's own preferences.
class AdSparkleStorage {
  AdSparkleStorage({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _prefix = 'adsparkle.';
  static const String _keyCompanyKey = '${_prefix}company_key';
  static const String _keyBaseUrl = '${_prefix}base_url';
  static const String _keyUserId = '${_prefix}user_id';
  static const String _keyClickId = '${_prefix}click_id';
  static const String _keyClickIds = '${_prefix}click_ids';
  static const String _keyClickIdsTs = '${_prefix}click_ids_ts';
  static const String _keyPendingQueue = '${_prefix}pending_queue';
  static const String _keyReferrerChecked = '${_prefix}referrer_checked';
  static const String _keyMatchChecked = '${_prefix}match_checked';
  static const String _keyIsSandbox = '${_prefix}is_sandbox';
  static const String _keyDeviceId = '${_prefix}device_id';
  static const String _keyDeferredEvents = '${_prefix}deferred_events';
  static const String _keyPendingRegisterClick = '${_prefix}pending_register_click';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<String?> getCompanyKey() async => (await _instance).getString(_keyCompanyKey);

  Future<void> setCompanyKey(String value) async =>
      (await _instance).setString(_keyCompanyKey, value);

  Future<String?> getBaseUrl() async => (await _instance).getString(_keyBaseUrl);

  Future<void> setBaseUrl(String value) async =>
      (await _instance).setString(_keyBaseUrl, value);

  Future<String?> getUserId() async => (await _instance).getString(_keyUserId);

  Future<void> setUserId(String value) async =>
      (await _instance).setString(_keyUserId, value);

  Future<String?> getClickId() async => (await _instance).getString(_keyClickId);

  Future<void> setClickId(String value) async =>
      (await _instance).setString(_keyClickId, value);

  Future<List<String>> getClickIds() async =>
      (await _instance).getStringList(_keyClickIds) ?? <String>[];

  Future<void> setClickIds(List<String> value) async =>
      (await _instance).setStringList(_keyClickIds, value);

  /// Returns the epoch-millisecond timestamp of the last click-chain update,
  /// or `null` if the chain has never been written.
  Future<int?> getClickIdsTs() async => (await _instance).getInt(_keyClickIdsTs);

  Future<void> setClickIdsTs(int value) async =>
      (await _instance).setInt(_keyClickIdsTs, value);

  /// Clears the persisted click chain and its timestamp (e.g. after the
  /// attribution window has elapsed).
  Future<void> clearClickIds() async {
    final prefs = await _instance;
    await prefs.remove(_keyClickIds);
    await prefs.remove(_keyClickIdsTs);
  }

  /// Whether the Android Play Install Referrer has already been queried once.
  /// The referrer is fixed at install time, so it is read a single time on the
  /// first configure(); this flag prevents re-querying. Unused on iOS.
  Future<bool> getReferrerChecked() async =>
      (await _instance).getBool(_keyReferrerChecked) ?? false;

  Future<void> setReferrerChecked(bool value) async =>
      (await _instance).setBool(_keyReferrerChecked, value);

  /// Whether the iOS probabilistic /match has already been attempted once
  /// (referrerChecked'in iOS karsiligi). Unused on non-iOS.
  Future<bool> getMatchChecked() async =>
      (await _instance).getBool(_keyMatchChecked) ?? false;

  Future<void> setMatchChecked(bool value) async =>
      (await _instance).setBool(_keyMatchChecked, value);

  /// ADIM 4: SDK sandbox modunda mı? configure()'da environment'tan BOOL olarak
  /// çözülüp yazılır (enum serialize edilmez). Varsayılan false (production).
  Future<bool> getIsSandbox() async =>
      (await _instance).getBool(_keyIsSandbox) ?? false;

  Future<void> setIsSandbox(bool value) async =>
      (await _instance).setBool(_keyIsSandbox, value);

  /// SDK'nin kendi urettigi KALICI cihaz UUID'si (iOS /match device_id — D2
  /// idempotency anahtari). null ise henuz uretilmemis.
  Future<String?> getDeviceId() async => (await _instance).getString(_keyDeviceId);

  Future<void> setDeviceId(String value) async =>
      (await _instance).setString(_keyDeviceId, value);

  /// click_id gelene kadar bekleyen olaylar (deferred attribution). pendingQueue
  /// ile ayni JSON-map depolama; ama farkli amac (click_id YOKKEN cagrilan track).
  Future<List<Map<String, dynamic>>> getDeferredEvents() async {
    final raw = (await _instance).getStringList(_keyDeferredEvents) ?? <String>[];
    final result = <Map<String, dynamic>>[];
    for (final entry in raw) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map<String, dynamic>) result.add(decoded);
      } catch (_) {/* bozuk kaydi atla */}
    }
    return result;
  }

  Future<void> setDeferredEvents(List<Map<String, dynamic>> value) async {
    final raw = value.map(jsonEncode).toList();
    await (await _instance).setStringList(_keyDeferredEvents, raw);
  }

  /// ADIM 5: Universal Link/App Links ile yakalanan bekleyen register-click
  /// istegi ({ unique_key, query_params, referrer? }). Basariya kadar SAKLANIR;
  /// configure()/track()'te tekrar denenir (E3). Basarida null'lanir.
  Future<Map<String, dynamic>?> getPendingRegisterClick() async {
    final raw = (await _instance).getString(_keyPendingRegisterClick);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setPendingRegisterClick(Map<String, dynamic>? value) async {
    final prefs = await _instance;
    if (value == null) {
      await prefs.remove(_keyPendingRegisterClick);
    } else {
      await prefs.setString(_keyPendingRegisterClick, jsonEncode(value));
    }
  }

  /// Returns the persisted pending event bodies as decoded JSON maps.
  Future<List<Map<String, dynamic>>> getPendingQueue() async {
    final raw = (await _instance).getStringList(_keyPendingQueue) ?? <String>[];
    final result = <Map<String, dynamic>>[];
    for (final entry in raw) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map<String, dynamic>) {
          result.add(decoded);
        }
      } catch (_) {
        // Skip corrupt entries.
      }
    }
    return result;
  }

  Future<void> setPendingQueue(List<Map<String, dynamic>> value) async {
    final raw = value.map(jsonEncode).toList();
    await (await _instance).setStringList(_keyPendingQueue, raw);
  }
}
