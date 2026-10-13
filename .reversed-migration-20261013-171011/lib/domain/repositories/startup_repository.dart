abstract interface class StartupRepository {
  Future<bool> hasSeenIntroduction();

  Future<void> markIntroductionSeen();
}
