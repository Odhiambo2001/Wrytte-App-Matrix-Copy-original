/// Separates the user-facing Wrytte-ID representation from its API form.
///
/// A Wrytte ID is displayed as `+00 212 123 3333`, but the backend receives
/// and stores the unambiguous identifier `W2121233333`. Real telephone
/// numbers remain conventional E.164 values such as `+15553334444`.
class WrytteId {
  const WrytteId._();

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
