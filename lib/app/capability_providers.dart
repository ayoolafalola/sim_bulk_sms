import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../platform/sms/sms_capability_service.dart';
import 'sending_providers.dart';

/// Real platform capabilities. Errors (e.g. running on a desktop host without
/// the native plugin) surface in the UI as "unavailable", never as success.
final capabilitiesProvider = FutureProvider<SmsCapabilities>(
    (ref) => ref.watch(smsServiceProvider).getCapabilities());
