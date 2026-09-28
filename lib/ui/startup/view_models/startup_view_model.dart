import 'package:wrytte/domain/repositories/startup_repository.dart';

class StartupViewModel {
  const StartupViewModel(this._repository, {required this.hasSeenIntroduction});

  final StartupRepository _repository;

  final bool hasSeenIntroduction;

  bool get shouldAnimateIntroduction => !hasSeenIntroduction;

  Future<void> completeStartup() async {
    if (!hasSeenIntroduction) {
      await _repository.markIntroductionSeen();
    }
  }
}
