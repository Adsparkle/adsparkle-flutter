import 'dart:io' show Platform;

/// dart:io tarafi — yalnizca native (mobil/masaustu) derlemede secilir
/// (match_client.dart conditional import ile). os_version buradan gelir.
String? osVersionRaw() {
  try {
    return Platform.operatingSystemVersion; // iOS: "Version 17.4 (Build 21E219)"
  } catch (_) {
    return null;
  }
}
