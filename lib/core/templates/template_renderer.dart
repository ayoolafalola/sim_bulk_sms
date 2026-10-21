/// Personalization (FR-05). Never emits an unresolved `{token}`.
class TemplateRenderResult {
  const TemplateRenderResult(this.text, this.unresolved);
  final String? text;            // null when unresolved variables remain
  final Set<String> unresolved;
  bool get ok => unresolved.isEmpty;
}

class TemplateRenderer {
  static final _token = RegExp(r'\{([a-z_][a-z0-9_]*)\}');
  static const builtIns = {'name', 'first_name', 'last_name', 'phone'};

  static Set<String> variablesIn(String template) =>
      _token.allMatches(template).map((m) => m.group(1)!).toSet();

  /// [values] holds per-recipient/custom values; [fallbacks] holds explicit
  /// user-chosen defaults. A blank value counts as missing.
  static TemplateRenderResult render(
    String template, {
    required String name,
    required String phone,
    Map<String, String> values = const {},
    Map<String, String> fallbacks = const {},
  }) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final resolved = <String, String>{
      'name': name.trim(),
      'first_name': parts.first,
      'last_name': parts.length > 1 ? parts.sublist(1).join(' ') : '',
      'phone': phone,
      ...values,
    };
    final missing = <String>{};
    final out = template.replaceAllMapped(_token, (m) {
      final key = m.group(1)!;
      final v = resolved[key];
      if (v != null && v.trim().isNotEmpty) return v;
      final f = fallbacks[key];
      if (f != null) return f;
      missing.add(key);
      return m.group(0)!;
    });
    return missing.isEmpty ? TemplateRenderResult(out, {}) : TemplateRenderResult(null, missing);
  }
}
