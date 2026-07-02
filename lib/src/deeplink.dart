/// Helpers for extracting an attribution `click_id` from deep link URIs.
class DeepLinkParser {
  const DeepLinkParser._();

  /// Query parameter that carries the attribution click identifier.
  static const String clickIdParam = 'click_id';

  /// Canonical (lowercase) UUID v4-shaped matcher. Matched case-insensitively.
  static final RegExp _uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Whether [value] is a syntactically valid attribution UUID.
  static bool isValidClickId(String value) => _uuidRe.hasMatch(value);

  /// Extracts the `click_id` query parameter from [uri], if present and a
  /// valid UUID. Returns `null` otherwise (missing, empty, or malformed).
  ///
  /// Example: `https://app.example.com/open?click_id=<uuid>` → `<uuid>`.
  static String? extractClickId(Uri uri) {
    final value = uri.queryParameters[clickIdParam];
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (!isValidClickId(trimmed)) return null;
    return trimmed;
  }
}
