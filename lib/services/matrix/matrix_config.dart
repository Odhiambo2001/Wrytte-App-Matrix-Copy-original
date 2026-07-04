class MatrixConfig {
  const MatrixConfig._();

  static const homeserver = String.fromEnvironment(
    'WRYTTE_MATRIX_HOMESERVER',
    defaultValue: 'http://31.220.58.129:8008',

    //'https://matrix.wrytte.com',
  );

  static const serverName = String.fromEnvironment(
    'WRYTTE_MATRIX_SERVER_NAME',
    defaultValue: 'matrix.wrytte.com',
  );

  static const appServiceName = 'Wrytte';
  static const pushAppId = 'com.example.wrytte';
  static const pushGatewayUrl =
      'https://wryttedev.azurewebsites.net/_matrix/push/v1/notify';
  static const localDatabaseName = 'wrytte_matrix';
  static const localDatabaseFile = 'wrytte_matrix.sqlite';
  //static const historyPageSize = 3000;
  // CHANGED: 3000 was being used as the /sync timeline limit, which made
  // every sync ask the homeserver for up to 3000 events per room. That is
  // what blew past the SDK's 10s sync guard and left rooms=0. History
  // pagination gets its own (still reduced) page size below.
  static const syncTimelineLimit = 10; // ADDED: per-room events on each /sync
  static const historyPageSize = 200; // CHANGED: was 3000 (used by requestHistory)


  static const localMediaMaxBytes = 512 * 1024 * 1024;
  static const localMediaTtl = Duration(days: 30);
}
