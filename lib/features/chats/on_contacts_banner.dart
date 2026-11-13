import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/settings_providers.dart';
import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../account/account_controller.dart';

/// Whether a number can get a Contacts++ chat (signed in, "chat first" on).
final chatTargetProvider = FutureProvider.family<ChatTarget?, String>((ref, e164) async {
  if (ref.watch(accountProvider).valueOrNull == null) return null;
  if (!await ref.watch(chatFirstProvider.future)) return null;
  return (await ref.read(contactsChatServiceProvider).reachability([e164]))[e164];
});

/// In a text conversation: "Bola is on Contacts++ · Chat instead".
class OnContactsBanner extends ConsumerWidget {
  const OnContactsBanner({super.key, required this.phone, required this.name});
  final String phone, name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e164 = ref.watch(phoneNormalizerProvider).normalize(phone).e164;
    if (e164 == null) return const SizedBox.shrink();
    final target = ref.watch(chatTargetProvider(e164)).valueOrNull;
    if (target == null) return const SizedBox.shrink();
    final c = AppColors.of(context);
    return Material(
      color: c.infoBg,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.forum_outlined, color: c.infoFg),
        title: Text('${target.displayName ?? name} is on Contacts++',
            style: TextStyle(color: c.infoFg, fontWeight: FontWeight.w700)),
        subtitle: Text('Chat for free; it reaches every device they use.', style: TextStyle(color: c.infoFg)),
        trailing: FilledButton.tonalIcon(
          onPressed: () async {
            try {
              final id = await ref.read(contactsChatServiceProvider).conversationWith(target);
              if (context.mounted) {
                context.push(Uri(path: '/messages/chat/$id', queryParameters: {'title': target.displayName ?? name})
                    .toString());
              }
            } on ContactsPlusException catch (e) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
            }
          },
          icon: const Icon(Icons.chat_outlined),
          label: const Text('Chat'),
        ),
      ),
    );
  }
}
