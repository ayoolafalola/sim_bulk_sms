import 'package:flutter/material.dart';
import 'theme.dart';
import 'app_info.dart';

/// Shown instead of a blank screen when the app cannot start.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.title, required this.detail});
  final String title, detail;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: appName,
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                SelectableText(detail, textAlign: TextAlign.center),
              ]),
            ),
          ),
        ),
      );
}
