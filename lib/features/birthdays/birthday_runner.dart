import 'package:sqflite/sqflite.dart';
import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/birthday_settings.dart';
import '../../domain/models/contact.dart';
import '../../domain/models/pro.dart';
import '../../domain/services/birthdays.dart';
import '../../domain/services/campaign_planner.dart';

enum BirthdayOutcome {
  /// Turned off.
  off,
  /// Turned on, but Comeriver Pro isn't active.
  needsPro,
  /// Not time yet today, or today already ran.
  notDue,
  /// Ran today: nobody (left) to wish.
  none,
  /// A campaign was created for today's birthdays.
  created,
}

class BirthdayRunResult {
  const BirthdayRunResult(this.outcome, {this.campaignId, this.people = 0, this.texts = 0});
  final BirthdayOutcome outcome;
  final int? campaignId;
  /// People wished, and how many of their messages are texts (the rest are emails).
  final int people, texts;
}

/// One person's upcoming birthday, for the list on the Birthday wishes screen.
class UpcomingBirthday {
  const UpcomingBirthday(this.contact, this.on);
  final Contact contact;
  final DateTime on;
  int? get turns => ageOn(contact.birthday, on);
}

const _monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Birthday wishes (Comeriver Pro): once a day, at the chosen time, everyone whose birthday it is (and who
/// hasn't been wished this year) gets the message, sent as an ordinary campaign run named
/// "Birthday wishes · 26 Oct". Opt-outs, suppression, send limits, signature and history all apply.
class BirthdayRunner {
  BirthdayRunner({required this.db, required this.settings, required this.contacts, required this.groups,
      required this.campaigns});
  final Database db;
  final SettingsRepository settings;
  final ContactRepository contacts;
  final GroupRepository groups;
  final CampaignRepository campaigns;

  /// When the next run is due: today at the chosen time if today hasn't run yet (possibly already past, so
  /// due now), else tomorrow. Null when off or without Pro.
  Future<DateTime?> nextRunAt(DateTime now) async {
    final s = await settings.loadBirthdays();
    if (!s.enabled || !(await settings.loadPro()).has(ProFeature.birthdayWishes)) return null;
    final today = DateTime(now.year, now.month, now.day, s.minuteOfDay ~/ 60, s.minuteOfDay % 60);
    return s.lastRunDate == dayKey(now) ? today.add(const Duration(days: 1)) : today;
  }

  Future<bool> isDue(DateTime now) async {
    final at = await nextRunAt(now);
    return at != null && !at.isAfter(now);
  }

  /// Who the wishes go to: everyone, or the members of the chosen groups.
  Future<List<Contact>> audience(BirthdaySettings s) async {
    if (s.groupIds.isEmpty) return contacts.search();
    final byId = <int, Contact>{};
    for (final g in s.groupIds) {
      for (final c in await groups.members(g)) {
        byId[c.id!] = c;
      }
    }
    return byId.values.toList();
  }

  /// Birthdays in the audience from [from] for [days] days, soonest first.
  Future<List<UpcomingBirthday>> upcoming(DateTime from, {int days = 30}) async {
    final s = await settings.loadBirthdays();
    final until = DateTime(from.year, from.month, from.day).add(Duration(days: days));
    return [
      for (final c in await audience(s))
        if (nextBirthday(c.birthday, from) case final on? when on.isBefore(until)) UpcomingBirthday(c, on),
    ]..sort((a, b) => a.on.compareTo(b.on));
  }

  Future<Set<int>> _wishedIn(int year) async => {
        for (final r in await db.query('birthday_wishes', columns: ['contact_id'], where: 'year = ?', whereArgs: [year]))
          r['contact_id'] as int,
      };

  /// Runs today's wishes if it's time. Creates a ready campaign; the caller sends it (automatically on
  /// Android, with a tap per text on iPhone).
  Future<BirthdayRunResult> runDue(DateTime now, {required String platform}) async {
    final s = await settings.loadBirthdays();
    if (!s.enabled) return const BirthdayRunResult(BirthdayOutcome.off);
    if (!(await settings.loadPro()).has(ProFeature.birthdayWishes)) return const BirthdayRunResult(BirthdayOutcome.needsPro);
    final today = dayKey(now);
    if (s.lastRunDate == today || now.hour * 60 + now.minute < s.minuteOfDay) {
      return const BirthdayRunResult(BirthdayOutcome.notDue);
    }
    // Claim the day first, so a crash or a second engine can never send twice.
    await settings.saveBirthdays(s.copyWith(lastRunDate: today));

    final wished = await _wishedIn(now.year);
    final people = [
      for (final c in await audience(s))
        if (c.id != null && !wished.contains(c.id) && isBirthdayOn(c.birthday, now)) c,
    ];
    if (people.isEmpty) return const BirthdayRunResult(BirthdayOutcome.none);
    final plan = buildSnapshotPlan(
      template: s.template, contacts: people, suppressedE164: await contacts.suppressedNumbers(),
      channel: s.channel, subjectTemplate: s.subject,
    );
    if (plan.recipients.isEmpty) return const BirthdayRunResult(BirthdayOutcome.none);

    final id = await campaigns.createDraft(
        name: 'Birthday wishes · ${now.day} ${_monthShort[now.month - 1]}', template: s.template, platform: platform,
        channel: s.channel, subject: s.channel.usesEmail ? s.subject : null);
    await campaigns.saveSnapshot(id, plan.recipients);
    final ids = {for (final r in plan.recipients) if (r.contactId != null) r.contactId!};
    final created = DateTime.now().toUtc().toIso8601String();
    final b = db.batch();
    for (final c in ids) {
      b.insert('birthday_wishes', {'contact_id': c, 'year': now.year, 'campaign_id': id, 'created_at': created},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await b.commit(noResult: true);
    return BirthdayRunResult(BirthdayOutcome.created, campaignId: id, people: ids.length, texts: plan.smsCount);
  }
}
