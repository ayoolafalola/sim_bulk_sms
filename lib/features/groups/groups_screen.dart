import 'package:flutter/material.dart';

/// Asks for a group name. Returns the trimmed name, or null if cancelled.
Future<String?> askGroupName(BuildContext context, {String initial = '', required String title}) async {
  final ctrl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Group name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
      ],
    ),
  );
  final t = name?.trim();
  return (t == null || t.isEmpty) ? null : t;
}
