import '../models/contact.dart';
import '../models/statuses.dart';

class EligibilityResult {
  const EligibilityResult(this.eligible, this.excludedSuppressed, this.excludedOptedOut, this.excludedInvalid);
  final List<Contact> eligible;
  final List<Contact> excludedSuppressed, excludedOptedOut, excludedInvalid;
  int get excludedCount => excludedSuppressed.length + excludedOptedOut.length + excludedInvalid.length;
}

/// FR-13. Suppression wins over everything; opted_out contacts are excluded;
/// contacts without a normalized number can't be sent to. `unknown` consent is
/// allowed but the UI should report how many unknown-consent recipients remain.
EligibilityResult filterEligible(List<Contact> contacts, Set<String> suppressedE164) {
  final ok = <Contact>[], sup = <Contact>[], opt = <Contact>[], inv = <Contact>[];
  final seen = <String>{};
  for (final c in contacts) {
    final n = c.phoneNormalized;
    if (n == null) { inv.add(c); continue; }
    if (suppressedE164.contains(n)) { sup.add(c); continue; }
    if (c.consent == ConsentStatus.optedOut) { opt.add(c); continue; }
    if (!seen.add(n)) continue; // same number twice in one selection: send once
    ok.add(c);
  }
  return EligibilityResult(ok, sup, opt, inv);
}
