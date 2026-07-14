import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:http/http.dart' as http;

// os_version: dart:io yalnizca native derlemede; web'de stub (null). Boylece
// bu dosya web'de de derlenir (install_referrer.dart ile ayni web-safe cizgi).
import 'platform_stub.dart' if (dart.library.io) 'platform_io.dart' as plat;

/// iOS deferred (probabilistic) attribution — `POST /api/tracking/match`.
///
/// iOS App Store referrer tasimaz (Android'in aksine); install ilk acildiginda
/// (deep-link/referrer ile click_id gelmediyse) cihaz sinyalleri + KALICI SDK
/// device_id yollanip son 60 dk iOS click'lerine olasilik-tabanli eslestirilir.
///
/// - YALNIZCA iOS (Android = deterministik Install Referrer; web = kavram yok).
/// - `device_id`: SDK'nin kendi kalici UUID'si (IDFV DEGIL — Dart IDFV'ye
///   erisemez). D2 tek-tuketim idempotency anahtari; ayni cihaz her /match'te
///   AYNI UUID. iOS guard'dan SONRA uretilir.
/// - Sinyaller web-safe kaynaklardan: ekran/locale dart:ui, os_version dart:io
///   (conditional import). `device_model` GONDERILMEZ (KARAR 1).
class MatchClient {
  MatchClient._();

  static Future<String?> resolveMatch({
    required String baseUrl,
    required Future<String> Function() getDeviceId,
    bool test = false,
    void Function(String message)? log,
  }) async {
    // /match yalnizca iOS. kIsWeb + defaultTargetPlatform web-safe guard.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;

    try {
      final body = <String, dynamic>{};

      // Ekran: dart:ui view physicalSize / devicePixelRatio → LOGICAL boyut,
      // portre-normalize (min/max) — interstitial JS (screen.width/height) ve
      // iOS native (UIScreen.bounds) ile tutarli. scale = devicePixelRatio.
      try {
        final views = ui.PlatformDispatcher.instance.views;
        if (views.isNotEmpty) {
          final view = views.first;
          final dpr = view.devicePixelRatio;
          if (dpr > 0) {
            final w = view.physicalSize.width / dpr;
            final h = view.physicalSize.height / dpr;
            body['screen_w'] = (w < h ? w : h).round();
            body['screen_h'] = (w < h ? h : w).round();
            body['scale'] = dpr;
          }
        }
      } catch (_) {/* atla */}

      // locale: dart:ui (web-safe) toLanguageTag → "en-US" (JS navigator.language
      // ve iOS native Locale ile ayni bicim). NOT: S2 spec'inde Platform.localeName
      // vardi ama o dart:io (web-safe degil) ve "en_US" bicimi verir; dart:ui daha uygun.
      try {
        final tag = ui.PlatformDispatcher.instance.locale.toLanguageTag();
        if (tag.isNotEmpty) body['locale'] = tag;
      } catch (_) {/* atla */}

      // tz: DateTime.timeZoneName — UYARI: KISALTMA ("+03"/"GMT+3"), IANA DEGIL.
      // Backend click tarafi IANA ("Europe/Istanbul") tuttugu icin ESLESMEZ →
      // tz +1 kazanilmaz (zararsiz; mismatch elimination YAPMAZ). Dart core IANA
      // veremez (peer dep gerekir; KARAR 4 peer dep YASAK). Gonderilir cunku
      // false-positive riski yok.
      try {
        final tz = DateTime.now().timeZoneName;
        if (tz.isNotEmpty) body['timezone'] = tz;
      } catch (_) {/* atla */}

      // UTC offset (dakika) — IANA veremesek de GARANTI sinyal (backend bunu tz
      // yedegi olarak +1 sayar). JS getTimezoneOffset() konvansiyonu (UTC+3 =>
      // -180): timeZoneOffset UTC+3'te +180 verir, isareti ters cevir.
      try {
        body['tz_offset'] = -DateTime.now().timeZoneOffset.inMinutes;
      } catch (_) {/* atla */}

      // os_version: dart:io Platform.operatingSystemVersion (conditional import;
      // web→null). Backend major.minor cikarir ("Version 17.4 (Build ...)"→17.4).
      final os = plat.osVersionRaw();
      if (os != null && os.isNotEmpty) body['os_version'] = os;

      // device_id (D2 idempotency): iOS guard'dan SONRA.
      final deviceId = await getDeviceId();
      if (deviceId.isNotEmpty) body['device_id'] = deviceId;

      // ADIM 4: sandbox → matchInstall çağrılmaz, backend sinyalleri yankılar.
      if (test) body['test'] = true;

      final base = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final resp = await http.post(
        Uri.parse('$base/api/tracking/match'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        log?.call('/match non-2xx (${resp.statusCode})');
        return null;
      }
      final data = jsonDecode(resp.body);
      if (data is Map &&
          data['success'] == true &&
          data['click_id'] is String &&
          (data['click_id'] as String).isNotEmpty) {
        log?.call('/match resolved a click_id');
        return data['click_id'] as String;
      }
      log?.call('/match no click_id');
      return null;
    } catch (_) {
      return null;
    }
  }
}
