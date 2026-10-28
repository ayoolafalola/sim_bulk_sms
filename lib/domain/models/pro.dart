import 'dart:convert';

/// What Comeriver Pro unlocks. Add a value here (and its check) for every new Pro feature;
/// [ProStatus.has] is the only question the rest of the app asks.
enum ProFeature {
  /// Change or remove the campaign signature (free: always [freeSignature]).
  customSignature,
  /// More than [FreeLimits.campaigns] campaigns.
  unlimitedCampaigns,
  /// More than [FreeLimits.schedules] schedule.
  unlimitedSchedules,
  /// More than [FreeLimits.emailsPerDay] emails a day.
  unlimitedEmail,
  /// Automatic birthday messages.
  birthdayWishes,
}

/// Limits of the free app.
class FreeLimits {
  static const campaigns = 5;
  static const schedules = 1;
  static const emailsPerDay = 50;
}

/// Added on its own line to every campaign text and email on the free app.
/// Plain characters only, so it never changes how a text is encoded.
const freeSignature = 'Sent via messages.comeriver.com';

/// Store product ids. Google Play: one subscription with monthly and yearly base plans.
/// App Store: two products in the "Comeriver Pro" group.
class ProProducts {
  static const playSubscription = 'comeriver_pro';
  static const appStoreMonthly = 'comeriver_pro_monthly';
  static const appStoreYearly = 'comeriver_pro_yearly';
  static const all = {playSubscription, appStoreMonthly, appStoreYearly};
}

/// The Pro subscription as last confirmed by Google Play / the App Store, kept in the
/// database so the background sender sees it too.
class ProStatus {
  const ProStatus({this.active = false, this.verifiedAt, this.expiresAt, this.productId, this.debugOverride = false});

  /// The store said there is an active subscription at [verifiedAt].
  final bool active;
  final DateTime? verifiedAt;
  /// When the store reported it ends (App Store); null when unknown (Google Play renews in place).
  final DateTime? expiresAt;
  final String? productId;
  /// Debug builds only: "Pretend Pro" switch for trying Pro features.
  final bool debugOverride;

  /// Without a fresh check (offline), a confirmed subscription counts for this long.
  static const offlineGrace = Duration(days: 7);

  bool isPro({DateTime? now}) {
    if (debugOverride) return true;
    if (!active || verifiedAt == null) return false;
    final n = now ?? DateTime.now();
    if (expiresAt != null && n.isAfter(expiresAt!.add(const Duration(days: 3)))) return false;
    return n.difference(verifiedAt!) < offlineGrace;
  }

  bool has(ProFeature f, {DateTime? now}) => isPro(now: now);

  ProStatus copyWith({bool? active, DateTime? verifiedAt, DateTime? expiresAt, String? productId, bool? debugOverride}) =>
      ProStatus(
        active: active ?? this.active, verifiedAt: verifiedAt ?? this.verifiedAt,
        expiresAt: expiresAt ?? this.expiresAt, productId: productId ?? this.productId,
        debugOverride: debugOverride ?? this.debugOverride,
      );

  String toJson() => jsonEncode({
        'active': active, 'verifiedAt': verifiedAt?.toUtc().toIso8601String(),
        'expiresAt': expiresAt?.toUtc().toIso8601String(), 'productId': productId, 'debug': debugOverride,
      });

  static ProStatus fromJson(String? s) {
    if (s == null) return const ProStatus();
    final m = jsonDecode(s) as Map<String, dynamic>;
    DateTime? t(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
    return ProStatus(
      active: m['active'] as bool? ?? false, verifiedAt: t(m['verifiedAt']), expiresAt: t(m['expiresAt']),
      productId: m['productId'] as String?, debugOverride: m['debug'] as bool? ?? false,
    );
  }
}

/// A free-plan limit was reached; [feature] is what Pro would unlock.
class ProRequiredException implements Exception {
  ProRequiredException(this.feature, this.message);
  final ProFeature feature;
  final String message;
  @override
  String toString() => message;
}

/// The campaign signature: free = [freeSignature]; Pro = the user's own (null = none).
String? campaignSignature(ProStatus pro, {String? custom, DateTime? now}) {
  if (!pro.has(ProFeature.customSignature, now: now)) return freeSignature;
  final c = custom?.trim() ?? '';
  return c.isEmpty ? null : c;
}

/// [message] with the signature on its own line (unchanged without one).
String withSignature(String message, String? signature) =>
    signature == null || signature.isEmpty ? message : '$message\n$signature';
