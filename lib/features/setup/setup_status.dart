import '../../platform/background/background_send_service.dart';
import '../../app/app_info.dart';

/// Everything the app asks the phone for. See [SetupStatus.required].
enum SetupItem { sms, notifications, exactAlarms, battery, contacts }

class SetupItemInfo {
  const SetupItemInfo(this.title, this.why, {this.ifMissing});
  final String title, why;
  /// What happens without it (shown in warnings).
  final String? ifMissing;
}

const setupInfo = <SetupItem, SetupItemInfo>{
  SetupItem.sms: SetupItemInfo('Default messaging app',
      'Lets the app send and receive your texts and send campaigns through your SIM automatically. '
          'Your existing messages stay where they are. Carrier charges apply.',
      ifMissing: 'Messages open in your Messages app instead, one tap each, and your texts aren\'t shown here.'),
  SetupItem.notifications: SetupItemInfo('Notifications',
      'Shows progress while sending and tells you when a scheduled run finishes or has a problem.',
      ifMissing: 'You won\'t see sending progress or results when the app is closed.'),
  SetupItem.exactAlarms: SetupItemInfo('Alarms & reminders',
      'Lets the app wake up at the exact time of a scheduled run or when a send limit resets, even when closed.',
      ifMissing: 'Scheduled runs only start while the app is open.'),
  SetupItem.battery: SetupItemInfo('Battery: Unrestricted',
      'Stops Android from delaying or blocking sending to save battery.\n'
          'On Samsung also: Settings › Battery › Background usage limits › Never sleeping apps › add $appName.',
      ifMissing: 'The phone may delay or stop background sends.'),
  SetupItem.contacts: SetupItemInfo('Contacts (optional)',
      'Only needed for "Import from phone". The app reads names and numbers; nothing is uploaded.'),
};

/// Store build: no automatic sending, so alarms only time the "campaign is due" reminder.
const _storeInfo = <SetupItem, SetupItemInfo>{
  SetupItem.notifications: SetupItemInfo('Notifications',
      'Tells you when a scheduled campaign is due so you can send it.',
      ifMissing: 'You won\'t be reminded when a scheduled campaign is due.'),
  SetupItem.exactAlarms: SetupItemInfo('Alarms & reminders',
      'Lets the app remind you at the exact time a scheduled campaign is due, even when it is closed.',
      ifMissing: 'Reminders for scheduled campaigns may come late or only when you open the app.'),
};

/// Texts for [item] in this build.
SetupItemInfo setupInfoFor(SetupItem item) => (isStoreBuild ? _storeInfo[item] : null) ?? setupInfo[item]!;

/// What's granted on this phone, and what's still missing.
class SetupStatus {
  const SetupStatus({required this.granted, this.permanentlyDenied = const {}, this.items = SetupItem.values,
      this.required = defaultRequired});
  final Map<SetupItem, bool> granted;
  final Set<SetupItem> permanentlyDenied;
  /// Items that apply to this phone (e.g. no SMS item without telephony).
  final List<SetupItem> items;

  /// Warned about until granted. Contacts is optional.
  static const defaultRequired = {SetupItem.sms, SetupItem.notifications, SetupItem.exactAlarms, SetupItem.battery};
  /// Store build: only what the reminders need.
  static const storeRequired = {SetupItem.notifications, SetupItem.exactAlarms};
  final Set<SetupItem> required;

  bool isOk(SetupItem i) => granted[i] ?? false;
  bool isRequired(SetupItem i) => required.contains(i);
  List<SetupItem> get missingRequired => [for (final i in items) if (isRequired(i) && !isOk(i)) i];
  bool get complete => missingRequired.isEmpty;

  factory SetupStatus.fromAndroid(BackgroundStatus b, {bool store = isStoreBuild}) => SetupStatus(
        required: store ? storeRequired : defaultRequired,
        granted: {
          SetupItem.sms: b.defaultSms,
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
        items: store
            ? const [SetupItem.notifications, SetupItem.exactAlarms, SetupItem.contacts]
            : [if (b.telephony) SetupItem.sms, SetupItem.notifications, SetupItem.exactAlarms, SetupItem.battery,
                SetupItem.contacts],
      );
}
