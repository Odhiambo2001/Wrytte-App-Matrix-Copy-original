import 'package:wrytte/data/services/startup_preferences_service.dart';
import 'package:wrytte/domain/repositories/startup_repository.dart';

class StartupRepositoryImpl implements StartupRepository {
  const StartupRepositoryImpl(this._service);

  final StartupPreferencesService _service;

  @override
  Future<bool> hasSeenIntroduction() => _service.hasSeenIntroduction();

  @override
  Future<void> markIntroductionSeen() => _service.markIntroductionSeen();
}
