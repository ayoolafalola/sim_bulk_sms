import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import 'setup_status.dart';

/// Asks for [item], or opens the right settings page when Android won't ask
/// again (refused for good) or it's a settings toggle, then re-checks.
Future<void> fixSetupItem(WidgetRef ref, SetupItem item, SetupStatus s) async {
  final bg = ref.read(backgroundSendServiceProvider);
  if (bg == null) return;
  final permanent = s.permanentlyDenied.contains(item);
  switch (item) {
    case SetupItem.sms:
      if (permanent) {
        await bg.openAppSettings();
      } else {
        await ref.read(smsServiceProvider).requestRequiredPermissions();
        ref.invalidate(capabilitiesProvider);
      }
    case SetupItem.notifications:
      if (permanent || !await bg.requestNotifications()) await bg.openNotificationSettings();
    case SetupItem.exactAlarms:
      await bg.openExactAlarmSettings();
    case SetupItem.battery:
      await bg.openBatterySettings();
    case SetupItem.contacts:
      if (permanent) {
        await bg.openAppSettings();
      } else {
        await ref.read(phoneContactsServiceProvider).requestPermission();
      }
  }
  ref.read(backgroundStatusVersionProvider.notifier).state++;
}

/// One checklist row: status, why it's needed, and a button to fix it.
class SetupItemCard extends ConsumerWidget {
  const SetupItemCard({super.key, required this.item, required this.status});
  final SetupItem item;
  final SetupStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = setupInfoFor(item);
    final ok = status.isOk(item);
    final permanent = status.permanentlyDenied.contains(item);
    final scheme = Theme.of(context).colorScheme;
    final opensSettings = permanent || item == SetupItem.exactAlarms || item == SetupItem.battery;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? Icons.check_circle : (status.isRequired(item) ? Icons.error_outline : Icons.radio_button_unchecked),
              color: ok ? scheme.primary : (status.isRequired(item) ? scheme.error : null)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(info.title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(info.why),
              if (!ok && info.ifMissing != null) ...[
                const SizedBox(height: 4),
                Text('Without it: ${info.ifMissing}', style: TextStyle(color: scheme.error)),
              ],
              if (!ok && permanent) ...[
                const SizedBox(height: 4),
                const Text('You refused this before, so Android won\'t ask again. '
                    'In app settings open Permissions and turn it on.'),
              ],
              if (!ok) ...[
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: () => fixSetupItem(ref, item, status),
                  child: Text(permanent ? 'Open app settings' : opensSettings ? 'Open settings' : 'Allow'),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
