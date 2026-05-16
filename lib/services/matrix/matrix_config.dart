class MatrixConfig {
  const MatrixConfig._();

  static const homeserver = String.fromEnvironment(
    'WRYTTE_MATRIX_HOMESERVER',
    defaultValue: 'https://matrix.wrytte.com',
  );

  static const serverName = String.fromEnvironment(
    'WRYTTE_MATRIX_SERVER_NAME',
    defaultValue: 'matrix.wrytte.com',
  );

  static const appServiceName = 'Wrytte';
  static const localDatabaseName = 'wrytte_matrix';
  static const localDatabaseFile = 'wrytte_matrix.sqlite';

  static const localMediaMaxBytes = 512 * 1024 * 1024;
  static const localMediaTtl = Duration(days: 30);
}
