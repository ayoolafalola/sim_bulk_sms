import 'package:flutter/material.dart';
import 'router.dart';
import 'theme.dart';

class SimBulkSmsApp extends StatelessWidget {
  const SimBulkSmsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'SIM Bulk SMS',
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        routerConfig: appRouter,
      );
}
