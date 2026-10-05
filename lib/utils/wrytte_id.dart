import 'package:wrytte/services/auth/wrytte_library.dart';

/// Separates the user-facing Wrytte-ID representation from its API form.
///
/// A Wrytte ID is displayed with `+00` and its library grouping, but the
/// backend receives and stores the unambiguous identifier `W2121233333`.
/// Real telephone numbers remain conventional E.164 values such as
/// `+15553334444`.
class WrytteId {
  const WrytteId._();

  /// Returns the user-facing Wrytte ID using the regional grouping in the
  /// Wrytte library. Regular international phone numbers are left untouched.
  static String? forDisplay(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final backendId = RegExp(
      r'^(?:@)?W(\d{8,12})(?::[^:]+)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (backendId != null) return _formatBody(backendId.group(1)!);

    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if ((trimmed.startsWith('+00') || trimmed.startsWith('00')) &&
        digits.startsWith('00')) {
      final body = digits.substring(2);
      if (body.length >= 8 && body.length <= 12) return _formatBody(body);
    }
    return null;
  }

  static String _formatBody(String body) {
    final rule = WrytteLibrary.resolvePrefix(body);
    final groupSizes = rule == null
        ? List<int>.filled((body.length / 3).ceil(), 3)
        : rule.format.split(' ').map(int.parse);
    final groups = <String>[];
    var offset = 0;
    for (final size in groupSizes) {
      if (offset >= body.length) break;
      final end = (offset + size).clamp(0, body.length);
      groups.add(body.substring(offset, end));
      offset = end;
    }
    if (offset < body.length) groups.add(body.substring(offset));
    return '+00 ${groups.join(' ')}';
  }

  /// Converts a visible `+00…` ID, a locally stored `00…` ID, or an existing
  /// canonical `W…` ID into the backend representation.
  ///
  /// Throws [FormatException] rather than silently turning a normal telephone
  /// number into a Wrytte ID.
  static String forBackend(String value) {
    final trimmed = value.trim();
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    final hasWPrefix = RegExp(r'^w', caseSensitive: false).hasMatch(trimmed);

    final body =
        hasWPrefix
            ? digits
            : digits.startsWith('00')
            ? digits.substring(2)
            : '';
    if (body.length < 4) {
      throw const FormatException('Invalid Wrytte ID');
    }
    return 'W$body';
  }
}
