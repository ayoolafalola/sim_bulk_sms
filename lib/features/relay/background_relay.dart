import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../data/database/app_database.dart';
import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../backup/backup_sync.dart';
import '../backup/campaign_plans.dart';
import '../campaigns/campaign_composer.dart';
import '../../platform/background/background_send_service.dart';
import '../../platform/contacts_plus/contacts_plus_auth.dart';
import '../../platform/contacts_plus/messages_push_service.dart';
import 'relay_runner.dart';

/// A push with the app closed.
///
/// "Something changed on the web" (`sync`): campaigns set up on the web are
/// saved and scheduled here, and the background service re-checks what is
/// due, so a web campaign sends at its time without opening the app.
///
/// "Texts from the web are waiting" (Android):
/// claim them and hand them to the background send service, which sends
/// them like any campaign. On iPhone the texts wait for the member to open
/// the app and tap Send.
@pragma('vm:entry-point')
Future<void> relayBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!MessagesFirebaseConfig.configured) return;
  if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: MessagesFirebaseConfig.options);
  if (message.data['type'] == 'sync') return _syncInBackground();
  if (message.data['type'] != 'relay' || !Platform.isAndroid) return;
  Database? db;
  try {
    db = await _openOwnConnection();
    final runner = RelayRunner(
      db: db,
      transport: ContactsRelayTransport(ContactsPlusAuth()),
      campaigns: CampaignRepository(db),
    );
    final service = NativeBackgroundSendService();
    // New texts, plus any an earlier push claimed but could not start.
    for (final id in {...await runner.claim(), ...await runner.unstarted()}) {
      await service.startSend(id);
    }
  } catch (e) {
    debugPrint('Messages++ relay push failed: $e');
  } finally {
    await db?.close();
  }
}

/// Pulls web changes (campaign plans, contacts, groups) and reports campaign
/// status, without the app open. Android then re-arms its wake-up.
Future<void> _syncInBackground() async {
  Database? db;
  try {
    db = await _openOwnConnection();
    final auth = ContactsPlusAuth();
    if (await auth.accessToken() == null) return;
    final campaigns = CampaignRepository(db);
    final sync = BackupSync(
      db: db,
      transport: ContactsSyncTransport(auth),
      plans: CampaignPlans(
        db: db,
        campaigns: campaigns,
        schedules: ScheduleRepository(db),
        composer: CampaignComposer(
          contacts: ContactRepository(db),
          groups: GroupRepository(db),
          campaigns: campaigns,
          proStatus: SettingsRepository(db).loadPro,
          sharedValues: () => contactsPlusSharedValues(auth),
        ),
        platform: Platform.isIOS ? 'ios' : 'android',
      ),
    );
    final report = await sync.run(full: false);
    if (report.downloaded > 0 && Platform.isAndroid) await NativeBackgroundSendService().checkNow();
  } catch (e) {
    debugPrint('Messages++ web sync push failed: $e');
  } finally {
    await db?.close();
  }
}

/// Its own connection, so closing it when the push is handled leaves the app
/// screen's and the send service's connection open.
Future<Database> _openOwnConnection() async =>
    openAppDatabase(databaseFactory, p.join(await getDatabasesPath(), 'sim_bulk_sms.db'), singleInstance: false);
