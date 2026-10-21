import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/phone_numbers/phone_normalizer.dart';

/// ISO region used to interpret local-format numbers. A settings screen will
/// make this user-selectable and persistent; until then it is a fixed default.
final defaultRegionProvider = StateProvider<String>((ref) => 'NG');

final phoneNormalizerProvider =
    Provider((ref) => PhoneNormalizer(ref.watch(defaultRegionProvider)));
