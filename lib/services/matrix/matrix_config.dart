class MatrixConfig {
  const MatrixConfig._();

  static const homeserver = String.fromEnvironment(
    'WRYTTE_MATRIX_HOMESERVER',
    defaultValue: 'https://matrix.wrytte.com',
  );

  static const serverName = String.fromEnvironment(
    'WRYTTE_MATRIX_SERVER_NAME',
    // Existing Synapse users are currently hosted under the Contabo IP. Keep
    // this aligned with the backend's MATRIX_SERVER_NAME until Synapse is
    // migrated to a DNS name. Builds can override it with --dart-define.
    defaultValue: '185.202.223.192',
  );

  /// Maximum time a single Matrix login/registration request may occupy the
  /// authentication flow. A failed Matrix bootstrap must not block backend
  /// authentication indefinitely.
  static const authRequestTimeout = Duration(seconds: 15);

  static const appServiceName = 'Wrytte';
  static const pushAppId = 'com.example.wrytte';
  static const pushGatewayUrl = String.fromEnvironment(
    'WRYTTE_MATRIX_PUSH_GATEWAY_URL',
    defaultValue: 'https://api.wrytte.com/_matrix/push/v1/notify',
  );
  static const localDatabaseName = 'wrytte_matrix';
  static const localDatabaseFile = 'wrytte_matrix.sqlite';
  //static const historyPageSize = 3000;
  // CHANGED: 3000 was being used as the /sync timeline limit, which made
  // every sync ask the homeserver for up to 3000 events per room. That is
  // what blew past the SDK's 10s sync guard and left rooms=0. History
  // pagination gets its own (still reduced) page size below.
  static const syncTimelineLimit = 10; // ADDED: per-room events on each /sync
  static const historyPageSize =
      200; // CHANGED: was 3000 (used by requestHistory)

  static const localMediaMaxBytes = 512 * 1024 * 1024;
  static const localMediaTtl = Duration(days: 30);
}
