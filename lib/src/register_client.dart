import 'dart:convert';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:http/http.dart' as http;

/// Tek bir register-click denemesinin sonucu (E3 retry karari — native
/// iOS/Android siniflandirmasiyla birebir).
enum RegisterOutcome {
  /// Sunucu click olusturdu; [RegisterResult.clickId] dolu.
  success,

  /// Kalici ret (4xx — 408/429 haric —, 2xx ama click_id yok, ya da
  /// desteklenmeyen platform). Tekrar denemek sonucu degistirmez; bekleyen
  /// istek TEMIZLENMELI (sonsuz yanlis-key dongusu olmasin).
  permanent,

  /// Gecici hata (ag hatasi, 5xx, 408, 429). Bekleyen istek KALIR; sonraki
  /// configure()/track()'te tekrar denenir.
  transient,
}

/// register-click deneme sonucu: [outcome] + basarida [clickId].
class RegisterResult {
  const RegisterResult._(this.outcome, this.clickId);

  const RegisterResult.success(String clickId)
      : this._(RegisterOutcome.success, clickId);

  static const RegisterResult permanent =
      RegisterResult._(RegisterOutcome.permanent, null);

  static const RegisterResult transient =
      RegisterResult._(RegisterOutcome.transient, null);

  final RegisterOutcome outcome;
  final String? clickId;
}

/// ADIM 5: register-click istemcisi (app-tetikli deterministic click).
///
/// Universal Link (iOS) / App Links (Android) ile app YUKLU acildiginda sistem
/// dogrudan app'i acar → sunucuya ugranmaz, ClickEvent olusmaz. `handleDeepLink`
/// bu istemciyle click'i APP olusturur: `unique_key`'den backend ClickEvent uretir.
///
/// - DETERMINISTIC: `device_id` = SDK'nin KALICI UUID'si (/match ile AYNI; E5 dedup),
///   `platform` = "ios"|"android". Cihaz fingerprint'i GONDERILMEZ → backend
///   hasJsFingerprint false → /match adayi olmaz.
/// - Basari → [RegisterResult.success]. Kalici hata (4xx — 408/429 haric — veya
///   2xx-click_id'siz) → [RegisterResult.permanent] (pending temizlenmeli).
///   Gecici hata (ag / 5xx / 408 / 429) → [RegisterResult.transient] (pending
///   kalir, E3). Throw etmez.
class RegisterClient {
  RegisterClient._();

  static Future<RegisterResult> resolve({
    required String baseUrl,
    required String companyKey,
    required String uniqueKey,
    required String deviceId,
    required Map<String, String> queryParams,
    String? referrer,
    bool test = false,
    void Function(String message)? log,
  }) async {
    // web'de Universal Link kavrami yok; retry sonucu degistirmez → KALICI.
    if (kIsWeb) return RegisterResult.permanent;
    final String? platform = defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : defaultTargetPlatform == TargetPlatform.android
            ? 'android'
            : null;
    if (platform == null) return RegisterResult.permanent;

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
      final status = resp.statusCode;
      if (status < 200 || status >= 300) {
        // Kalici/gecici ayrimi (E3, PostbackClient ile ayni siniflandirma):
        // 4xx (408/429 haric) → KALICI (yanlis company_key / bilinmeyen
        // unique_key vb.; pending temizlenir, sonsuz yanlis-key dongusu olmaz).
        // 5xx / 408 / 429 → GECICI (retry ust katmanda pending ile yapilir).
        if (status >= 400 && status < 500 && status != 408 && status != 429) {
          log?.call('register-click permanently failed (status $status)');
          return RegisterResult.permanent;
        }
        log?.call('register-click transient failure (status $status)');
        return RegisterResult.transient;
      }
      final data = jsonDecode(resp.body);
      if (data is Map &&
          data['success'] == true &&
          data['click_id'] is String &&
          (data['click_id'] as String).isNotEmpty) {
        log?.call('register-click resolved a click_id');
        return RegisterResult.success(data['click_id'] as String);
      }
      // 2xx ama click_id yok (success:false vb.) → sunucu karar verdi;
      // ayni istegi tekrarlamak sonucu degistirmez → KALICI.
      log?.call('register-click 2xx without click_id — permanent');
      return RegisterResult.permanent;
    } catch (_) {
      // Ag hatasi / bozuk yanit govdesi → GECICI (E3). Asla throw etme.
      return RegisterResult.transient;
    }
  }
}
