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
