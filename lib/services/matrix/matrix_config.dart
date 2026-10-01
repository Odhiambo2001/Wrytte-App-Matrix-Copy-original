class MatrixConfig {
  const MatrixConfig._();

  static const homeserver = String.fromEnvironment(
    'WRYTTE_MATRIX_HOMESERVER',
    defaultValue: 'https://matrix.wrytte.com',
  );

  static const serverName = String.fromEnvironment(
    'WRYTTE_MATRIX_SERVER_NAME',
    defaultValue: 'wrytte.com',
  );

  static const authRequestTimeout = Duration(seconds: 15);

  static const appServiceName = 'Wrytte';
  static const pushAppId = 'com.example.wrytte';

  static const pushGatewayUrl = String.fromEnvironment(
    'WRYTTE_MATRIX_PUSH_GATEWAY_URL',
    defaultValue: 'https://api.wrytte.com/_matrix/push/v1/notify',
  );

  // Local client cache only. This is not the production server database.
  static const localDatabaseName = 'wrytte_matrix';
  static const localDatabaseFile = 'wrytte_matrix.sqlite';

  static const syncTimelineLimit = 10;
  static const historyPageSize = 200;

  static const localMediaMaxBytes = 512 * 1024 * 1024;
  static const localMediaTtl = Duration(days: 30);
}
