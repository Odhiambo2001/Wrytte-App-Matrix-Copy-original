/// Thrown when the OpenIM SDK login fails permanently (after all retries).
///
/// Catch this specifically when you need to distinguish chat unavailability
/// from authentication errors elsewhere in the app.
///
/// Example:
/// ```dart
/// try {
///   await AuthService.instance.loginToOpenIM(...);
/// } on OpenImLoginException catch (e) {
///   // Chat is down — app stays usable, surface a banner
///   log(e.toString());
/// }
/// ```
class OpenImLoginException implements Exception {
  const OpenImLoginException(this.message, {this.cause});

  final String message;

  /// The underlying error from the last failed attempt, if any.
  final Object? cause;

  @override
  String toString() => 'OpenImLoginException: $message'
      '${cause != null ? ' (caused by: $cause)' : ''}';
}
