import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../../domain/models/channels.dart';
import '../../domain/models/email_settings.dart';
import '../../domain/models/pro.dart';
import '../../domain/services/email_body.dart';
import '../../platform/email/email_sender.dart';
import '../../platform/email/google_gmail_auth.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';

/// Settings › Email: how campaign emails are sent (a Mailgun-compatible API or
/// Gmail), the sender, email limits and the unsubscribe line. Test before use.
class EmailSettingsScreen extends ConsumerStatefulWidget {
  const EmailSettingsScreen({super.key, this.gmailSupported});
  /// Overrides whether this build can use Gmail (tests).
  final bool? gmailSupported;

  @override
  ConsumerState<EmailSettingsScreen> createState() => _EmailSettingsScreenState();
}

class _EmailSettingsScreenState extends ConsumerState<EmailSettingsScreen> {
  EmailSettings? _s;
  final _base = TextEditingController(), _domain = TextEditingController(), _key = TextEditingController(),
      _fromName = TextEditingController(), _fromAddress = TextEditingController(),
      _hourly = TextEditingController(), _daily = TextEditingController(), _unsub = TextEditingController();
  bool _showKey = false, _busy = false;

  bool get _gmailSupported => widget.gmailSupported ?? _safeGmailAvailable();
  static bool _safeGmailAvailable() {
    try {
      return gmailAvailable;
    } catch (_) {
      return false; // e.g. web
    }
  }

  @override
  void initState() {
    super.initState();
    ref.read(settingsRepositoryProvider).loadEmail().then((s) {
      if (!mounted) return;
      _base.text = s.baseUrl;
      _domain.text = s.domain;
      _key.text = s.apiKey;
      _fromName.text = s.fromName;
      _fromAddress.text = s.fromAddress;
      _hourly.text = '${s.hourlyLimit}';
      _daily.text = '${s.dailyLimit}';
      _unsub.text = s.unsubscribeText;
      setState(() => _s = s);
    });
  }

  @override
  void dispose() {
    for (final c in [_base, _domain, _key, _fromName, _fromAddress, _hourly, _daily, _unsub]) {
      c.dispose();
    }
    super.dispose();
  }

  EmailSettings _current() => _s!.copyWith(
        baseUrl: _base.text.trim(), domain: _domain.text.trim(), apiKey: _key.text.trim(),
        fromName: _fromName.text.trim(), fromAddress: _fromAddress.text.trim(),
        hourlyLimit: int.tryParse(_hourly.text.trim()) ?? _s!.hourlyLimit,
        dailyLimit: int.tryParse(_daily.text.trim()) ?? _s!.dailyLimit,
        unsubscribeText: _unsub.text,
      );

  /// What's wrong with the form, or null.
  String? _problem(EmailSettings s) {
    if (s.provider == EmailProvider.mailgun) {
      if (!s.baseUrl.startsWith('https://')) return 'The API base URL must start with https://';
      if (s.domain.isEmpty) return 'Enter your sending domain.';
      if (s.apiKey.isEmpty) return 'Enter your API key.';
      if (!isValidEmail(s.fromAddress)) return 'Enter the address emails come from.';
    }
    if (s.provider == EmailProvider.gmail && s.gmailAccount == null) return 'Connect your Gmail account.';
    return null;
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<bool> _save({bool quiet = false}) async {
    final s = _current();
    final p = _problem(s);
    if (p != null) {
      _snack(p);
      return false;
    }
    await ref.read(settingsRepositoryProvider).saveEmail(s);
    _s = s;
    ref.read(dataVersionProvider.notifier).state++;
    if (!quiet) _snack('Email settings saved.');
    return true;
  }

  Future<void> _connectGmail() async {
    setState(() => _busy = true);
    try {
      final email = await ref.read(gmailAuthProvider).connect();
      setState(() => _s = _current().copyWith(gmailAccount: email));
      await _save(quiet: true);
      _snack('Connected $email.');
    } catch (e) {
      _snack('Could not connect Gmail: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnectGmail() async {
    await ref.read(gmailAuthProvider).disconnect();
    setState(() => _s = _current().copyWith(clearGmail: true, provider: EmailProvider.off));
    await ref.read(settingsRepositoryProvider).saveEmail(_s!);
    ref.read(dataVersionProvider.notifier).state++;
  }

  Future<void> _sendTest() async {
    if (!await _save(quiet: true)) return;
    final s = _s!;
    if (!mounted) return;
    final to = TextEditingController(text: s.senderAddress);
    final address = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send a test email to'),
        content: TextField(controller: to, keyboardType: TextInputType.emailAddress, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, to.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (address == null || !isValidEmail(address)) return;
    final sender = ref.read(emailSenderFactoryProvider)(s);
    if (sender == null) return;
    setState(() => _busy = true);
    String message;
    try {
      await sender.prepare();
      final body = emailBodies('This is a test from Comeriver Messages. Your email settings work.', s);
      final r = await sender.send(OutgoingEmail(
          id: 'test-${DateTime.now().millisecondsSinceEpoch}', campaignId: 0, toAddress: address,
          subject: 'Test email', text: body.text, html: body.html));
      message = switch (r.outcome) {
        EmailOutcome.sent => 'Sent to $address. Check the inbox (and the spam folder).',
        EmailOutcome.failed => 'Not sent: ${r.errorMessage ?? r.errorCode}',
        EmailOutcome.unknown => 'No clear answer: ${r.errorMessage ?? r.errorCode}. Check the inbox.',
      };
    } on EmailNotReadyException catch (e) {
      message = e.message;
    } catch (e) {
      message = 'Not sent: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test email'),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) {
      return Scaffold(appBar: AppBar(title: const Text('Email')), body: const Center(child: CircularProgressIndicator()));
    }
    final muted = AppColors.of(context).muted;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Scaffold(
      appBar: AppBar(title: const Text('Email')),
      body: FormPage(
        action: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        children: [
          Text('Campaigns can send emails as well as texts. Emails go out by themselves, also on iPhone.',
              style: TextStyle(color: muted)),
          const SectionLabel('Send emails with'),
          SegmentedButton<EmailProvider>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: EmailProvider.off, label: Text('Off')),
              ButtonSegment(value: EmailProvider.mailgun, label: Text('Mailgun API')),
              ButtonSegment(value: EmailProvider.gmail, label: Text('Gmail')),
            ],
            selected: {s.provider},
            onSelectionChanged: (v) => setState(() => _s = _current().copyWith(provider: v.first)),
          ),
          if (s.provider == EmailProvider.mailgun) ...[
            const SizedBox(height: 12),
            Text('Mailgun, or any email service with the same API (change the base URL).',
                style: TextStyle(color: muted, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(controller: _base, keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'API base URL')),
            Wrap(spacing: 8, children: [
              ActionChip(label: const Text('Mailgun US'), onPressed: () => setState(() => _base.text = EmailSettings.mailgunUs)),
              ActionChip(label: const Text('Mailgun EU'), onPressed: () => setState(() => _base.text = EmailSettings.mailgunEu)),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _domain, keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Sending domain', hintText: 'mg.example.com')),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: !_showKey,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API key',
                suffixIcon: IconButton(
                  tooltip: _showKey ? 'Hide' : 'Show',
                  icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: _fromAddress, keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'From address', hintText: 'news@mg.example.com')),
          ],
          if (s.provider == EmailProvider.gmail) ...[
            const SizedBox(height: 12),
            if (!_gmailSupported)
              Text('Gmail isn\'t set up in this build of the app yet. It needs a Google Cloud project; '
                  'see docs/GMAIL_SETUP.md. Until then, use the Mailgun API.',
                  style: TextStyle(color: AppColors.of(context).warnFg))
            else if (s.gmailAccount == null)
              OutlinedButton.icon(
                onPressed: _busy ? null : _connectGmail,
                icon: const Icon(Icons.login),
                label: const Text('Connect Gmail'),
              )
            else
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.mark_email_read_outlined),
                  title: Text(s.gmailAccount!),
                  subtitle: const Text('Sends as this account. The app can only send, not read your mail.'),
                  trailing: TextButton(onPressed: _disconnectGmail, child: const Text('Disconnect')),
                ),
              ),
            const SizedBox(height: 8),
            Text('Personal Gmail allows about 500 emails a day.', style: TextStyle(color: muted, fontSize: 13)),
          ],
          if (s.provider != EmailProvider.off) ...[
            const SizedBox(height: 12),
            TextField(controller: _fromName, textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'From name', hintText: 'Grace Church')),
            const SectionLabel('Email limits'),
            if (!(ref.watch(proStatusProvider).valueOrNull?.isPro() ?? false))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('The free app sends up to ${FreeLimits.emailsPerDay} emails a day, whatever is set here. '
                    'Pro uses your own limits.', style: TextStyle(color: muted, fontSize: 13)),
              ),
            Row(children: [
              Expanded(
                child: TextField(controller: _hourly, keyboardType: TextInputType.number, inputFormatters: digits,
                    decoration: const InputDecoration(labelText: 'Per hour', helperText: '0 = no limit')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(controller: _daily, keyboardType: TextInputType.number, inputFormatters: digits,
                    decoration: const InputDecoration(labelText: 'Per day', helperText: '0 = no limit')),
              ),
            ]),
            const SectionLabel('Unsubscribe line'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Add an unsubscribe line'),
              subtitle: const Text('Many countries require a way to opt out of bulk email.'),
              value: s.unsubscribeOn,
              onChanged: (v) => setState(() => _s = _current().copyWith(unsubscribeOn: v)),
            ),
            if (s.unsubscribeOn)
              TextField(controller: _unsub, minLines: 1, maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Line at the end of each email')),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _sendTest,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.outgoing_mail),
              label: const Text('Send test email'),
            ),
          ],
        ],
      ),
    );
  }
}
