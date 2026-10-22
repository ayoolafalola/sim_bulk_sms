import '../../platform/background/background_send_service.dart';

/// Everything the app asks the phone for. See [SetupStatus.required].
enum SetupItem { sms, notifications, exactAlarms, battery, contacts }

class SetupItemInfo {
  const SetupItemInfo(this.title, this.why, {this.ifMissing});
  final String title, why;
  /// What happens without it (shown in warnings).
  final String? ifMissing;
}

const setupInfo = <SetupItem, SetupItemInfo>{
  SetupItem.sms: SetupItemInfo('Send SMS',
      'Lets the app send messages through your SIM automatically. Carrier charges apply.',
      ifMissing: 'Messages open in your Messages app instead, one tap each.'),
  SetupItem.notifications: SetupItemInfo('Notifications',
      'Shows progress while sending and tells you when a scheduled run finishes or has a problem.',
      ifMissing: 'You won\'t see sending progress or results when the app is closed.'),
  SetupItem.exactAlarms: SetupItemInfo('Alarms & reminders',
      'Lets the app wake up at the exact time of a scheduled run or when a send limit resets, even when closed.',
      ifMissing: 'Scheduled runs only start while the app is open.'),
  SetupItem.battery: SetupItemInfo('Battery: Unrestricted',
      'Stops Android from delaying or blocking sending to save battery.\n'
          'On Samsung also: Settings › Battery › Background usage limits › Never sleeping apps › add SIM Bulk SMS.',
      ifMissing: 'The phone may delay or stop background sends.'),
  SetupItem.contacts: SetupItemInfo('Contacts (optional)',
      'Only needed for "Import from phone". The app reads names and numbers; nothing is uploaded.'),
};

/// What's granted on this phone, and what's still missing.
class SetupStatus {
  const SetupStatus({required this.granted, this.permanentlyDenied = const {}, this.items = SetupItem.values});
  final Map<SetupItem, bool> granted;
  final Set<SetupItem> permanentlyDenied;
  /// Items that apply to this phone (e.g. no SMS item without telephony).
  final List<SetupItem> items;

  /// Warned about until granted. Contacts is optional.
  static const required = {SetupItem.sms, SetupItem.notifications, SetupItem.exactAlarms, SetupItem.battery};

  bool isOk(SetupItem i) => granted[i] ?? false;
  bool isRequired(SetupItem i) => required.contains(i);
  List<SetupItem> get missingRequired => [for (final i in items) if (isRequired(i) && !isOk(i)) i];
  bool get complete => missingRequired.isEmpty;

  factory SetupStatus.fromAndroid(BackgroundStatus b) => SetupStatus(
        granted: {
          SetupItem.sms: b.sms,
          SetupItem.notifications: b.notifications,
          SetupItem.exactAlarms: b.exactAlarms,
          SetupItem.battery: b.batteryUnrestricted,
          SetupItem.contacts: b.contacts,
        },
        permanentlyDenied: {
          if (b.smsPermanentlyDenied) SetupItem.sms,
          if (b.contactsPermanentlyDenied) SetupItem.contacts,
          if (b.notificationsPermanentlyDenied) SetupItem.notifications,
        },
        items: [if (b.telephony) SetupItem.sms, SetupItem.notifications, SetupItem.exactAlarms, SetupItem.battery,
          SetupItem.contacts],
      );
}
