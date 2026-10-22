import 'package:flutter/material.dart';

/// Padding for a scrolling page body that keeps the last items clear of the
/// system navigation/gesture bar (Android draws edge-to-edge) and, with
/// [extra], of a floating action button or simply leaves room to scroll past.
EdgeInsets pagePadding(BuildContext context, {double extra = 0}) =>
    EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom + extra);

/// Extra bottom room for lists under a FloatingActionButton.
const fabClearance = 88.0;

/// A form page: scrolling [children] with an action area pinned below them.
/// Because the action area is part of the body (not the Scaffold's bottom
/// bar), it rises with the keyboard and stays tappable while typing.
class FormPage extends StatelessWidget {
  const FormPage({super.key, required this.children, this.action});
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: children,
        ),
      ),
      if (action != null)
        Material(
          elevation: 3,
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            top: false,
            // With the keyboard open the Scaffold already sits above it; no nav-bar inset needed.
            bottom: !keyboardOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: SizedBox(width: double.infinity, child: action),
            ),
          ),
        ),
    ]);
  }
}
