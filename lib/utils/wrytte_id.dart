/// Separates the user-facing Wrytte-ID representation from its API form.
///
/// A Wrytte ID is displayed as `+00 2121233333`, but the backend receives
/// and stores the unambiguous identifier `W2121233333`. Real telephone
/// numbers remain conventional E.164 values such as `+15553334444`.
class WrytteId {
  const WrytteId._();

  /// Returns the user-facing `+00 …` form for a canonical Wrytte ID or
  /// Matrix user ID. Regular international phone numbers are left untouched.
  static String? forDisplay(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final backendId = RegExp(
      r'^(?:@)?W(\d{8,12})(?::[^:]+)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (backendId != null) return '+00 ${backendId.group(1)}';

    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if ((trimmed.startsWith('+00') || trimmed.startsWith('00')) &&
        digits.startsWith('00')) {
      final body = digits.substring(2);
      if (body.length >= 8 && body.length <= 12) return '+00 $body';
    }
    return null;
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
