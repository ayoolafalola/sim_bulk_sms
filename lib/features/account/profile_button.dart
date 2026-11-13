import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import 'account_controller.dart';

/// Top-right of the Messages tab: the member's Contacts++ photo (or an avatar
/// when they have none, or are signed out). Opens the Contacts++ account screen.
class ProfileButton extends ConsumerWidget {
  const ProfileButton({super.key});

  static const _size = 36.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).valueOrNull;
    final photo = account == null ? null : ref.watch(profilePhotoProvider).valueOrNull;
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final Widget avatar;
    if (photo != null) {
      avatar = CircleAvatar(radius: _size / 2, backgroundImage: MemoryImage(photo));
    } else if (account != null) {
      avatar = CircleAvatar(
        radius: _size / 2,
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.person, color: scheme.onPrimaryContainer, size: 22),
      );
    } else {
      avatar = Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.muted, width: 1.5)),
        child: Icon(Icons.person_outline, color: c.muted, size: 22),
      );
    }
    return IconButton(
      tooltip: account == null ? 'Sign in with Contacts++' : 'Contacts++ account · ${account.displayName}',
      padding: const EdgeInsets.all(6),
      onPressed: () => context.push('/settings/account'),
      icon: avatar,
    );
  }
}
