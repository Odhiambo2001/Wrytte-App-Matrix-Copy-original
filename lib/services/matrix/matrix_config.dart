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
  static const historyPageSize = 3000;

  static const localMediaMaxBytes = 512 * 1024 * 1024;
  static const localMediaTtl = Duration(days: 30);
}
