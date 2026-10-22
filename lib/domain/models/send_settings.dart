/// User-adjustable sending safety settings. A limit of 0 means "off".
class SendSettings {
  const SendSettings({
    this.delaySeconds = defaultDelaySeconds,
    this.hourlyLimit = defaultHourlyLimit,
    this.dailyLimit = defaultDailyLimit,
    this.defaultRegion = defaultRegionCode,
  });
  static const defaultDelaySeconds = 3;
  static const defaultHourlyLimit = 100;
  static const defaultDailyLimit = 300;
  static const defaultRegionCode = 'NG';
  static const minDelay = 1, maxDelay = 30;

  /// Pause between two messages (Android direct sending).
  final int delaySeconds;
  /// Messages sent from this phone in any rolling 60 minutes / 24 hours.
  final int hourlyLimit, dailyLimit;
  /// ISO country used for numbers typed without +country code.
  final String defaultRegion;

  Duration get delay => Duration(seconds: delaySeconds);

  SendSettings copyWith({int? delaySeconds, int? hourlyLimit, int? dailyLimit, String? defaultRegion}) => SendSettings(
        delaySeconds: delaySeconds ?? this.delaySeconds,
        hourlyLimit: hourlyLimit ?? this.hourlyLimit,
        dailyLimit: dailyLimit ?? this.dailyLimit,
        defaultRegion: defaultRegion ?? this.defaultRegion,
      );
}
