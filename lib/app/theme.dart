import 'package:flutter/material.dart';

ThemeData buildTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF1B6B5A),
      brightness: b,
      visualDensity: VisualDensity.standard,
    );
