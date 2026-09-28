import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'package:wrytte/core/theme.dart';
import 'package:wrytte/data/repositories/startup_repository_impl.dart';
import 'package:wrytte/data/services/startup_preferences_service.dart';
import 'package:wrytte/domain/repositories/startup_repository.dart';
import 'package:wrytte/ui/startup/widgets/splash_logo_animation.dart';
import 'package:wrytte/ui/startup/view_models/startup_view_model.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key, required this.nextScreen});

  final WidgetBuilder nextScreen;

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  StartupViewModel? _viewModel;
  bool? _hasSeenIntroduction;
  bool _completing = false;

  @override
  void initState() {
    super.initState();
    FlutterNativeSplash.remove();
    _loadIntroductionState();
  }

  Future<void> _loadIntroductionState() async {
    final StartupRepository repository = StartupRepositoryImpl(
      StartupPreferencesService(),
    );
    var hasSeenIntroduction = false;
    try {
      hasSeenIntroduction = await repository.hasSeenIntroduction();
    } catch (error) {
      debugPrint('[StartupScreen] intro preference read failed: $error');
    }

    if (mounted) {
      setState(() {
        _viewModel = StartupViewModel(
          repository,
          hasSeenIntroduction: hasSeenIntroduction,
        );
        _hasSeenIntroduction = hasSeenIntroduction;
      });
    }
  }

  Future<void> _complete() async {
    if (_completing || !mounted) return;
    _completing = true;

    try {
      await _viewModel?.completeStartup();
    } catch (error) {
      debugPrint('[StartupScreen] intro preference write failed: $error');
    }

    if (!mounted) return;
    await Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute<void>(builder: widget.nextScreen));
  }

  @override
  Widget build(BuildContext context) {
    final hasSeenIntroduction = _hasSeenIntroduction;

    return Scaffold(
      backgroundColor: WrytteColors.background,
      body:
          hasSeenIntroduction == null
              ? const SizedBox.expand()
              : SplashLogoAnimation(
                animate: _viewModel!.shouldAnimateIntroduction,
                onCompleted: _complete,
              ),
    );
  }
}
