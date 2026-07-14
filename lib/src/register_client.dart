import 'dart:convert';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:http/http.dart' as http;

/// ADIM 5: register-click istemcisi (app-tetikli deterministic click).
///
/// Universal Link (iOS) / App Links (Android) ile app YUKLU acildiginda sistem
/// dogrudan app'i acar → sunucuya ugranmaz, ClickEvent olusmaz. `handleDeepLink`
/// bu istemciyle click'i APP olusturur: `unique_key`'den backend ClickEvent uretir.
///
/// - DETERMINISTIC: `device_id` = SDK'nin KALICI UUID'si (/match ile AYNI; E5 dedup),
///   `platform` = "ios"|"android". Cihaz fingerprint'i GONDERILMEZ → backend
///   hasJsFingerprint false → /match adayi olmaz.
/// - Basari → `click_id`. 4xx/5xx/hata → `null` (cagiran sessizce gecer, E3). Throw etmez.
class RegisterClient {
  RegisterClient._();

  static Future<String?> resolve({
    required String baseUrl,
    required String companyKey,
    required String uniqueKey,
    required String deviceId,
    required Map<String, String> queryParams,
    String? referrer,
    bool test = false,
    void Function(String message)? log,
  }) async {
    if (kIsWeb) return null; // web'de Universal Link kavrami yok.
    final String? platform = defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : defaultTargetPlatform == TargetPlatform.android
            ? 'android'
            : null;
    if (platform == null) return null;

    try {
      final body = <String, dynamic>{
        'unique_key': uniqueKey,
        'company_key': companyKey,
        'device_id': deviceId,
        'platform': platform,
      };
      if (queryParams.isNotEmpty) body['query_params'] = queryParams;
      if (referrer != null && referrer.isNotEmpty) body['referrer'] = referrer;
      // ADIM 4: sandbox → backend ClickEvent YAZMAZ, sentetik click_id döner.
      if (test) body['test'] = true;

      final base = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final resp = await http.post(
        Uri.parse('$base/api/tracking/register-click'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        log?.call('register-click non-2xx (${resp.statusCode})');
        return null; // 4xx (yanlis company_key vb.) / 5xx → null (E3)
      }
      final data = jsonDecode(resp.body);
      if (data is Map &&
          data['success'] == true &&
          data['click_id'] is String &&
          (data['click_id'] as String).isNotEmpty) {
        log?.call('register-click resolved a click_id');
        return data['click_id'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
