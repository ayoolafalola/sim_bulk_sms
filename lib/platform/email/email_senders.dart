import '../../domain/models/email_settings.dart';
import 'email_sender.dart';
import 'gmail_sender.dart';
import 'mailgun_sender.dart';

/// Builds the sender for the chosen provider, or null when email is off.
EmailSender? emailSenderFor(EmailSettings s, {GmailAuth? gmail, HttpPost? post}) => switch (s.provider) {
      EmailProvider.off => null,
      EmailProvider.mailgun => MailgunSender(s, post: post),
      EmailProvider.gmail => gmail == null ? null : GmailSender(s, gmail, post: post),
    };
