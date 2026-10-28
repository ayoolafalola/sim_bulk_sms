import 'package:flutter/material.dart';
import '../../domain/models/contact.dart';
import '../../domain/services/birthdays.dart';

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
    'October', 'November', 'December'];

/// A form row showing a birthday ("17 May 1990", or "17 May" without a year); tapping it picks one.
/// [value] and [onChanged] use the stored form (`YYYY-MM-DD` / `--MM-DD`, null = none).
class BirthdayField extends StatelessWidget {
  const BirthdayField({super.key, required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final picked = await pickBirthday(context, value);
          if (picked != null) onChanged(picked.isEmpty ? null : picked);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Birthday',
            suffixIcon: const Icon(Icons.cake_outlined),
            hintText: 'Add a birthday',
          ),
          isEmpty: value == null,
          child: value == null ? null : Text(formatContactDate(value!)),
        ),
      );
}

/// Day, month and an optional year. Returns the stored form, '' to remove it, or null if cancelled.
Future<String?> pickBirthday(BuildContext context, String? current) {
  final b = birthdayParts(current);
  var day = b?.day ?? 1, month = b?.month ?? 1;
  final year = TextEditingController(text: b?.year?.toString() ?? '');
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Birthday'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            SizedBox(
              width: 84,
              child: DropdownButtonFormField<int>(
                initialValue: day,
                decoration: const InputDecoration(labelText: 'Day'),
                items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                onChanged: (v) => setState(() => day = v ?? day),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: month,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Month'),
                items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(_monthNames[m - 1]))],
                onChanged: (v) => setState(() => month = v ?? month),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: year,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: InputDecoration(labelText: 'Year (optional)', errorText: error, counterText: ''),
          ),
        ]),
        actions: [
          if (current != null) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final y = year.text.trim().isEmpty ? null : int.tryParse(year.text.trim());
              final stored = (year.text.trim().isNotEmpty && y == null) ? null : storeBirthday(y, month, day);
              if (stored == null) {
                setState(() => error = 'That isn\'t a real date.');
                return;
              }
              Navigator.pop(ctx, stored);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}
