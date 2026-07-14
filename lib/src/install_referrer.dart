import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Android Play Install Referrer bridge (deferred / install attribution).
///
/// The native side (android/.../AdsparkleFlutterPlugin.kt) opens an
/// `InstallReferrerClient`, reads the Play Install Referrer, and extracts the
/// `click_id`. This is DETERMINISTIC: unlike iOS (the App Store passes no
/// referrer), the Play Store carries `referrer=click_id=<uuid>` through the
/// store install, so the install is attributed to the exact click without any
/// probabilistic matching.
///
/// Returns the `click_id` on success, or `null` for every non-happy path:
///   - not running on Android (incl. web),
///   - the plugin's native side is absent (app not rebuilt with this plugin),
///   - the referrer carries no `click_id`,
///   - any error.
///
/// Never throws — attribution must not crash the host app.
class InstallReferrer {
  InstallReferrer._();

  /// Must match the channel name in AdsparkleFlutterPlugin.kt.
  static const MethodChannel _channel =
      MethodChannel('co.adsparkle/install_referrer');

  static Future<String?> readClickId() async {
    // `defaultTargetPlatform` (not dart:io Platform) keeps this web-safe.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final clickId =
          await _channel.invokeMethod<String>('getInstallReferrer');
      if (clickId != null && clickId.trim().isNotEmpty) {
        return clickId.trim();
      }
      return null;
    } catch (_) {
      // MissingPluginException (not rebuilt), PlatformException, anything else.
      return null;
    }
  }
}
