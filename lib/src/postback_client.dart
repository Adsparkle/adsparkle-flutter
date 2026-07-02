import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Result of a single postback attempt.
enum PostbackOutcome {
  /// The server acknowledged the event (2xx).
  success,

  /// A transient failure (5xx or a network error). Safe to retry / queue.
  retryable,

  /// A permanent failure (4xx). The event should be dropped, not queued.
  permanent,
}

/// Sends attribution postbacks to the tracking API with retry + backoff.
class PostbackClient {
  PostbackClient({
    http.Client? httpClient,
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(milliseconds: 500),
    void Function(String message)? logger,
  })  : _http = httpClient ?? http.Client(),
        _log = logger;

  static const String _postbackPath = '/api/tracking/postback';

  final http.Client _http;
  final int maxAttempts;
  final Duration baseBackoff;
  final void Function(String message)? _log;

  /// Posts [body] to `{baseUrl}/api/tracking/postback` authenticated with the
  /// publishable [companyKey].
  ///
  /// Retries up to [maxAttempts] times with exponential backoff on retryable
  /// failures (5xx / network errors). Returns the final [PostbackOutcome].
  Future<PostbackOutcome> send({
    required String baseUrl,
    required String companyKey,
    required Map<String, dynamic> body,
  }) async {
    final uri = Uri.parse('${_trimTrailingSlash(baseUrl)}$_postbackPath');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Company-Key': companyKey,
    };
    final payload = jsonEncode(body);

    PostbackOutcome outcome = PostbackOutcome.retryable;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await _http.post(uri, headers: headers, body: payload);
        final status = response.statusCode;
        if (status >= 200 && status < 300) {
          return PostbackOutcome.success;
        }
        if (status >= 500) {
          outcome = PostbackOutcome.retryable;
          _log?.call('postback $status (attempt $attempt/$maxAttempts), retrying');
        } else {
          _log?.call('postback $status — permanent failure, dropping event');
          return PostbackOutcome.permanent;
        }
      } on SocketException catch (e) {
        outcome = PostbackOutcome.retryable;
        _log?.call('postback network error (attempt $attempt/$maxAttempts): $e');
      } on http.ClientException catch (e) {
        outcome = PostbackOutcome.retryable;
        _log?.call('postback client error (attempt $attempt/$maxAttempts): $e');
      } on TimeoutException catch (e) {
        outcome = PostbackOutcome.retryable;
        _log?.call('postback timeout (attempt $attempt/$maxAttempts): $e');
      }

      if (attempt < maxAttempts) {
        await Future<void>.delayed(baseBackoff * (1 << (attempt - 1)));
      }
    }

    return outcome;
  }

  /// Releases the underlying HTTP client.
  void close() => _http.close();

  static String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
