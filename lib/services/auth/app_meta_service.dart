class AppMetaService {
  AppMetaService._();
  static final AppMetaService instance = AppMetaService._();

  Future<bool> ping() async => true;

  Future<Map<String, dynamic>> getVersion() async => {
        'version': '1.0.0',
      };

  Future<Map<String, dynamic>> getStats() async => {};
}
