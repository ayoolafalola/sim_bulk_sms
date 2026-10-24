import 'package:flutter/material.dart';
import '../features/scheduling/schedule_ticker.dart';
import 'router.dart';
import 'theme.dart';
import 'app_info.dart';

class SimBulkSmsApp extends StatelessWidget {
  const SimBulkSmsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: appName,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        routerConfig: appRouter,
        builder: (context, child) => ScheduleTicker(child: _Readable(child: child ?? const SizedBox.shrink())),
      );
}

/// On tablets (iPad, large Android) the app keeps a comfortable reading width, centred, instead of
/// stretching lists and forms across the whole screen. Phones are unaffected.
class _Readable extends StatelessWidget {
  const _Readable({required this.child});
  final Widget child;
  static const maxWidth = 760.0;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= maxWidth + 80) return child;
    final ground = Theme.of(context).brightness == Brightness.dark ? const Color(0xFF0B0F0E) : const Color(0xFFEDE9E1);
    return ColoredBox(
      color: ground,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: MediaQuery(
            // Children lay out (and size dialogs and sheets) for the column, not the full screen.
            data: MediaQuery.of(context).copyWith(size: Size(maxWidth, MediaQuery.sizeOf(context).height)),
            child: ClipRect(child: child),
          ),
        ),
      ),
    );
  }
}
