import 'package:flutter/material.dart';
import '../../app/theme.dart';

/// Colour tone for a status tag; every tag also carries a text label, so
/// colour is never the only signal.
enum Tone { success, warn, danger, info, neutral }

(Color bg, Color fg) toneColors(BuildContext context, Tone t) {
  final c = AppColors.of(context);
  return switch (t) {
    Tone.success => (c.successBg, c.successFg),
    Tone.warn => (c.warnBg, c.warnFg),
    Tone.danger => (c.dangerBg, c.dangerFg),
    Tone.info => (c.infoBg, c.infoFg),
    Tone.neutral => (c.neutralBg, Theme.of(context).colorScheme.onSurface),
  };
}

/// Small rounded label, e.g. "Completed", "SMS", "Email".
class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, this.tone = Tone.neutral});
  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = toneColors(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// "SCHEDULED", "RECENT"… section heading in lists.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
        child: Row(children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: AppColors.of(context).muted)),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Big screen title used at the top of each tab ("Campaigns", "Contacts").
class TabTitle extends StatelessWidget {
  const TabTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.headlineMedium)),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Friendly empty state: what this is, and the one thing to do next.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title, text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Scrolls when the space is short (small phones, a tall banner above it).
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight.isFinite ? box.maxHeight : 0),
          child: Center(child: _content(context, c)),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, AppColors c) {
    return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: c.successBg, borderRadius: BorderRadius.circular(24)),
            child: Icon(icon, size: 34, color: c.successFg),
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.45)),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      );
  }
}

/// Round initials avatar with a soft tint picked from the name.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar(this.name, {super.key, this.size = 44});
  final String name;
  final double size;

  static const _light = [Color(0xFFDDEFE9), Color(0xFFFBE7D3), Color(0xFFE3E8FA), Color(0xFFF6E0EA),
    Color(0xFFE8E2F7), Color(0xFFFFF1C7), Color(0xFFDFF0F7)];
  static const _dark = [Color(0xFF1F4A3F), Color(0xFF4A3420), Color(0xFF26305A), Color(0xFF4A2638),
    Color(0xFF352B55), Color(0xFF4A3A10), Color(0xFF1D3F4A)];

  @override
  Widget build(BuildContext context) {
    final t = name.trim();
    final initials = t.isEmpty || t.startsWith('+') || RegExp(r'^\d').hasMatch(t)
        ? '#'
        : t.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).take(2).map((p) => p[0].toUpperCase()).join();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final palette = dark ? _dark : _light;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: palette[t.hashCode.abs() % palette.length], shape: BoxShape.circle),
      child: Text(initials, style: TextStyle(fontWeight: FontWeight.w700, fontSize: size * 0.36)),
    );
  }
}

/// Thin rounded progress bar.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.value, this.tone = Tone.success});
  final double value;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final fg = switch (tone) {
      Tone.warn => const Color(0xFFC98A00),
      Tone.danger => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.primary,
    };
    // Glides to each new value instead of jumping.
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value.clamp(0, 1).toDouble()),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOut,
        builder: (_, v, __) => LinearProgressIndicator(value: v, minHeight: 8, backgroundColor: c.neutralBg, color: fg),
      ),
    );
  }
}
