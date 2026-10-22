import 'package:flutter/services.dart';

/// Opens the phone's default Messages app with a number and text filled in.
/// The user taps Send there; the result is not reported back.
abstract class MessagesApp {
  /// False if no Messages app could be opened.
  Future<bool> open(String phone, String body);
  /// Several recipients in the "To" field. The Messages app may make it a group message.
  Future<bool> openMany(List<String> phones, String body);
}

class NativeMessagesApp implements MessagesApp {
  static const _ch = MethodChannel('app.sim_bulk_sms/sms_methods');
  @override
  Future<bool> open(String phone, String body) async =>
      await _ch.invokeMethod<bool>('openComposer', {'phone': phone, 'body': body}) ?? false;
  @override
  Future<bool> openMany(List<String> phones, String body) async =>
      await _ch.invokeMethod<bool>('openComposer', {'phones': phones, 'body': body}) ?? false;
}
