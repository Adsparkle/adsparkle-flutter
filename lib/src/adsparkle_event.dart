/// The built-in attribution event types supported by the platform.
///
/// These are provided as a convenience for the typed helpers; a company's
/// custom-event shortId may also be sent as the `event_type` (see
/// [AdSparkleEvent.eventType]). The wire value (sent in the postback
/// `event_type` field) is exposed via [wireName].
enum AdSparkleEventType {
  install('install'),
  signUp('sign_up'),
  login('login'),
  download('download'),
  purchase('purchase'),
  subscription('subscription'),
  refund('refund');

  const AdSparkleEventType(this.wireName);

  /// The value sent in the `event_type` field of the postback body.
  final String wireName;

  /// Resolves an [AdSparkleEventType] from its [wireName], or `null` if the
  /// given string is not a recognised event type.
  static AdSparkleEventType? fromWire(String value) {
    for (final type in AdSparkleEventType.values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

/// An attribution event ready to be serialised into a postback body.
///
/// Instances are immutable. The [toJson] map is exactly the request body
/// described by the tracking API contract; `null` fields are omitted.
class AdSparkleEvent {
  AdSparkleEvent({
    required this.clickId,
    required this.eventType,
    required this.userId,
    this.clickIds,
    this.transactionId,
    this.amount,
    this.currency,
    this.productIds,
    this.customParams,
  });

  final String clickId;
  final List<String>? clickIds;

  /// The raw `event_type` wire value. This is either a built-in type's
  /// [AdSparkleEventType.wireName] or a company custom-event shortId. Sent
  /// as-is in the postback body.
  final String eventType;
  final String userId;
  final String? transactionId;
  final num? amount;
  final String? currency;
  final List<String>? productIds;
  final Map<String, String>? customParams;

  /// Serialises this event into the JSON postback body. Optional fields that
  /// are `null` (or empty, for lists/maps) are omitted entirely.
  Map<String, dynamic> toJson() {
    final body = <String, dynamic>{
      'click_id': clickId,
      'event_type': eventType,
      'user_id': userId,
    };

    if (clickIds != null && clickIds!.isNotEmpty) {
      body['click_ids'] = clickIds;
    }
    if (transactionId != null) {
      body['transaction_id'] = transactionId;
    }
    if (amount != null) {
      body['amount'] = amount;
    }
    if (currency != null) {
      body['currency'] = currency;
    }
    if (productIds != null && productIds!.isNotEmpty) {
      body['product_ids'] = productIds;
    }
    if (customParams != null && customParams!.isNotEmpty) {
      body['custom_params'] = customParams;
    }

    return body;
  }

  /// Reconstructs an event from a previously persisted [toJson] map.
  static AdSparkleEvent? fromJson(Map<String, dynamic> json) {
    final clickId = json['click_id'];
    final eventTypeRaw = json['event_type'];
    final userId = json['user_id'];
    if (clickId is! String || eventTypeRaw is! String || userId is! String) {
      return null;
    }
    if (eventTypeRaw.isEmpty) return null;

    return AdSparkleEvent(
      clickId: clickId,
      eventType: eventTypeRaw,
      userId: userId,
      clickIds: _stringList(json['click_ids']),
      transactionId: json['transaction_id'] as String?,
      amount: json['amount'] as num?,
      currency: json['currency'] as String?,
      productIds: _stringList(json['product_ids']),
      customParams: _stringMap(json['custom_params']),
    );
  }

  static List<String>? _stringList(Object? value) {
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return null;
  }

  static Map<String, String>? _stringMap(Object? value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return null;
  }
}
