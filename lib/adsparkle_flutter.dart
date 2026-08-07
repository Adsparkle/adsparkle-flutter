/// AdSparkle — Flutter client SDK for the AdSparkle affiliate
/// attribution tracking platform.
///
/// Deterministic Android install attribution via the Play Install Referrer
/// (the SDK's only platform channel); pure Dart on every other platform. Use
/// [AdSparkle.instance] to configure the SDK and send attribution events.
library adsparkle_flutter;

export 'src/adsparkle.dart' show AdSparkle, AdSparkleEnvironment;
export 'src/adsparkle_event.dart' show AdSparkleEventType;
