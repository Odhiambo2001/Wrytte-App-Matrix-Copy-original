import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/ui/screens/source_chat_preview_screen.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wrytte/data/repositories/camera_repository_impl.dart';
import 'package:wrytte/data/repositories/media_library_repository_impl.dart';
import 'package:wrytte/data/services/camera_capabilities_service.dart';
import 'package:wrytte/data/services/camera_session_manager.dart';
import 'package:wrytte/data/services/device_camera_service.dart';
import 'package:wrytte/data/services/device_media_library_service.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:wrytte/ui/auth/auth_entry_screen.dart';
import 'package:wrytte/ui/auth/welcome_view.dart';
import 'package:wrytte/ui/auth/email_verification_page.dart';
import 'package:wrytte/ui/auth/login_email_verification_page.dart';
import 'package:wrytte/ui/auth/phone_auth_page.dart';
import 'package:wrytte/ui/auth/otp_verification_page.dart';
import 'package:wrytte/ui/auth/view_models/profile_setup_view_model.dart';
import 'package:wrytte/ui/auth/views/profile_setup_view.dart';
import 'package:wrytte/ui/auth/kface_view.dart';
import 'package:wrytte/ui/auth/sign_in_page.dart';
import 'package:wrytte/ui/auth/virtual_number_page.dart';

import 'package:wrytte/ui/screens/home_screen.dart';
import 'package:wrytte/ui/startup/views/startup_screen.dart';
import 'package:wrytte/ui/screens/terms_privacy_page.dart';
import 'package:wrytte/ui/widgets/theme_wrapper.dart';

import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/services/face/android_tflite_image_session.dart';

import 'firebase_options.dart';
import 'core/theme.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

const _systemBarColor = Colors.transparent;

Widget _profileSetupRoute() => ThemeWrapper(
  child: MultiProvider(
    providers: [
      Provider<CameraRepository>(
        create:
            (_) => CameraRepositoryImpl(
              DeviceCameraService(),
              const CameraCapabilitiesService(),
              CameraSessionManager(),
            ),
        dispose: (_, repository) => unawaited(repository.close()),
      ),
      Provider<MediaLibraryRepository>(
        create: (_) => MediaLibraryRepositoryImpl(DeviceMediaLibraryService()),
      ),
      ChangeNotifierProvider(create: (_) => ProfileSetupViewModel()),
    ],
    child: const ProfileSetupView(),
  ),
);

Future<(String?, String?)> _completeProfileSetup(String profileName) async {
  try {
    await UserProfileService.instance.updateDisplayName(profileName);
  } catch (error) {
    debugPrint('[ProfileSetupRoute] display name save failed: $error');
  }
  return (
    await AuthService.instance.getCurrentUserId(),
    await AuthService.instance.getSavedPhone(),
  );
}

Widget _profileSetupCompletionRoute(String profileName) => FutureBuilder(
  future: _completeProfileSetup(profileName),
  builder: (context, snapshot) {
    final session = snapshot.data;
    final userId = session?.$1;
    if (!snapshot.hasData || userId == null || userId.isEmpty) {
      return const Scaffold(
        backgroundColor: Color(0xFF08090B),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return ThemeWrapper(
      child: HomeScreen(
        currentUserId: userId,
        initialProfileName: profileName,
        initialPhone: session!.$2,
        isFirstSignup: true,
      ),
    );
  },
);

void apkLog(String tag, String message) {
  debugPrint('[$tag] $message');
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await _ensureFirebaseInitialized();
  await NotificationService.instance.showRemoteMessage(message);
}

Future<void> _ensureFirebaseInitialized() async {
  if (Firebase.apps.isNotEmpty) return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

final Completer<void> _startupServicesCompleter = Completer<void>();
Future<void> get _startupServicesReady => _startupServicesCompleter.future;

Future<void> _initializeStartupServices() async {
  try {
    await Future.wait<void>([Hive.initFlutter(), _ensureFirebaseInitialized()]);
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (error, stackTrace) {
    debugPrint('[Startup] essential service initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    if (!_startupServicesCompleter.isCompleted) {
      _startupServicesCompleter.complete();
    }
  }
}

void _startDeferredWarmups() {
  unawaited(
    AndroidTfliteImageSession.prewarm(
      'assets/models/retinaface_mv2.tflite',
    ).catchError((Object error, StackTrace stackTrace) {
      debugPrint(
        '[BiometricTiming] pipeline=RetinaFace stage=prewarm_error error=$error',
      );
    }),
  );
  unawaited(MatrixClientService.instance.ensureInitialized());
}

void main() {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  unawaited(
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
  );
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: _systemBarColor,
      systemNavigationBarColor: _systemBarColor,
      systemNavigationBarDividerColor: _systemBarColor,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  runApp(const WrytteApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initializeStartupServices());
  });
}

class WrytteApp extends StatelessWidget {
  const WrytteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wrytte',
      debugShowCheckedModeBanner: false,
      theme: WrytteTheme.lightTheme,
      home: StartupScreen(
        nextScreen: (_) => const ThemeWrapper(child: AuthWrapper()),
        onAnimationCompleted: _startDeferredWarmups,
      ),
      routes: {
        '/source-chat-preview': (context) =>
            const ThemeWrapper(child: SourceChatPreviewScreen()),
        '/welcome': (context) => const ThemeWrapper(child: WelcomeView()),
        '/auth': (context) => const ThemeWrapper(child: AuthEntryScreen()),
        '/auth_entry_screen':
            (context) => const ThemeWrapper(child: AuthEntryScreen()),
        '/auth/profile': (context) => _profileSetupRoute(),
        '/auth/wrytte-id': (context) {
          final routeRegion =
              ModalRoute.of(context)?.settings.arguments as String?;
          return ThemeWrapper(
            child: VirtualNumberPage(
              regionCode:
                  routeRegion ??
                  WidgetsBinding
                      .instance
                      .platformDispatcher
                      .locale
                      .countryCode ??
                  'US',
            ),
          );
        },
        '/auth/kface': (context) {
          final args =
              ModalRoute.of(context)?.settings.arguments
                  as Map<String, dynamic>?;
          final wrytteId = (args?['wrytteId'] ?? '').toString();
          return ThemeWrapper(
            child: KfaceView(
              wrytteId: wrytteId,
              isEnrollment: args?['isEnrollment'] as bool? ?? true,
              userId: args?['userId'] as String?,
              attachToExistingUser:
                  args?['attachToExistingUser'] as bool? ?? false,
            ),
          );
        },

        '/phone_auth': (context) => const ThemeWrapper(child: PhoneAuthPage()),

        '/virtual_phone':
            (context) => ThemeWrapper(
              child: VirtualNumberPage(
                regionCode:
                    WidgetsBinding
                        .instance
                        .platformDispatcher
                        .locale
                        .countryCode ??
                    'US',
              ),
            ),

        '/sign_in': (context) => const ThemeWrapper(child: SignInPage()),

        '/otp_verification': (context) {
          final args =
              ModalRoute.of(context)?.settings.arguments
                  as Map<String, dynamic>?;
          return ThemeWrapper(
            child: OtpVerificationPage(
              phoneNumber: args?['phoneNumber'] ?? '',
              isSignInFlow: args?['isSignInFlow'] ?? false,
            ),
          );
        },

        '/email_verification': (context) {
          final args =
              ModalRoute.of(context)?.settings.arguments
                  as Map<String, dynamic>?;
          return ThemeWrapper(
            child: EmailVerificationPage(
              email: args?['email'] ?? '',
              virtualNumber: args?['virtualNumber'] ?? '',
            ),
          );
        },

        '/login_otp_page': (context) => const ThemeWrapper(child: SignInPage()),

        '/login_email_verification_page': (context) {
          final args =
              ModalRoute.of(context)?.settings.arguments
                  as Map<String, dynamic>?;
          return ThemeWrapper(
            child: LoginEmailVerificationPage(
              email: args?['email'] ?? '',
              virtualNumber: args?['wrytteId'] ?? '',
            ),
          );
        },

        '/add_profile': (context) => _profileSetupRoute(),

        '/home': (context) {
          final arguments = ModalRoute.of(context)?.settings.arguments;
          if (arguments is Map) {
            final profileName = arguments['profileName']?.toString().trim();
            final userId = arguments['userId']?.toString().trim();
            final phone = arguments['phone']?.toString();
            if (profileName != null &&
                profileName.isNotEmpty &&
                userId != null &&
                userId.isNotEmpty) {
              return ThemeWrapper(
                child: HomeScreen(
                  currentUserId: userId,
                  initialProfileName: profileName,
                  initialPhone: phone,
                  isFirstSignup: true,
                ),
              );
            }
            if (profileName != null && profileName.isNotEmpty) {
              return _profileSetupCompletionRoute(profileName);
            }
          }

          final profileName = arguments as String?;
          return profileName == null || profileName.trim().isEmpty
              ? const ThemeWrapper(child: AuthWrapper())
              : _profileSetupCompletionRoute(profileName.trim());
        },

        'terms_privacy':
            (context) => const ThemeWrapper(child: TermsPrivacyPage()),
      },
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _checking = true;
  bool _isLoggedIn = false;
  bool _needsProfile = false;
  String? _currentUserId;
  String? _currentUsername;
  String? _currentPhone;
  List<Contact> _initialSavedContacts = const [];

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    try {
      await _startupServicesReady;
      final user = await AuthService.instance.getCurrentUser();
      final loggedIn = user != null && user.isAuthenticated;
      final userId = user?.userId;

      if (loggedIn && userId != null && userId.isNotEmpty) {
        // Establish the owner-scoped Matrix client before any background
        // service reads it. This removes the startup "not initialized" race.
        await MatrixClientService.instance.ensureInitialized(
          storeNamespace: userId,
        );
        await AuthService.instance.getValidBackendToken().timeout(
          const Duration(seconds: 2),
          onTimeout: () => '',
        );
        final profile = await AuthService.instance.hydrateStoredProfile(userId);
        final savedContacts = await ContactLocalDb.loadSavedContacts(
          ownerUserId: userId,
        );
        await ChatService()
            .hydrateLocalConversations()
            .timeout(const Duration(seconds: 2), onTimeout: () {});
        unawaited(_prewarmInitialSavedContactAvatars(savedContacts));
        _initServicesInBackground(userId: userId, nickname: user.username);

        final name = profile?.username ?? user.username;
        final needsProfile =
            name.isEmpty ||
            name.trim().length < 2 ||
            _looksLikePhone(name.trim());

        if (mounted) {
          setState(() {
            _isLoggedIn = loggedIn;
            _currentUserId = userId;
            _currentUsername = name;
            _currentPhone = user.phone;
            _initialSavedContacts = savedContacts;
            _needsProfile = needsProfile;
            _checking = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoggedIn = false;
            _checking = false;
          });
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        FlutterNativeSplash.remove();
      });
    } catch (e) {
      debugPrint('[AuthWrapper] Session check error: $e');
      if (mounted) {
        setState(() {
          _isLoggedIn = false;
          _checking = false;
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FlutterNativeSplash.remove();
      });
    }
  }

  bool _looksLikePhone(String value) {
    final s = value.replaceAll(RegExp(r'[\s\-()]'), '');
    return s.startsWith('+') || RegExp(r'^\d{6,}$').hasMatch(s);
  }

  Future<void> _prewarmInitialSavedContactAvatars(
    List<Contact> contacts,
  ) async {
    final token = AuthService.instance.cachedBackendToken;
    final seen = <String>{};
    for (final contact in contacts) {
      final url = _resolveAvatarUrl(contact.avatarUrl);
      if (url.isEmpty || !seen.add(url)) continue;
      await _warmImage(
            CachedNetworkImageProvider(
              url,
              headers: _avatarAuthHeaders(url, token),
            ),
          )
          .timeout(const Duration(seconds: 4), onTimeout: () {})
          .catchError((_) {});
    }
  }

  Future<void> _warmImage(ImageProvider provider) {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, __) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  String _resolveAvatarUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
    return url.startsWith('/') ? '${ApiService.baseUrl}$url' : url;
  }

  Map<String, String>? _avatarAuthHeaders(String url, String? token) {
    final clean = token?.trim() ?? '';
    if (clean.isEmpty) return null;
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final isWrytteImage =
        url.startsWith('${ApiService.baseUrl}/usrimg/') ||
        url.startsWith('/usrimg/') ||
        ApiService.isBackendHost(host) ||
        host == 'wrytte.com';
    if (!isWrytteImage) return null;
    return {'Authorization': 'Bearer $clean'};
  }

  @override
  void dispose() {
    unawaited(NotificationService.instance.stop());
    super.dispose();
  }

  Future<void> _initServicesInBackground({
    required String userId,
    String nickname = '',
  }) async {
    unawaited(
      ChatService().connect().catchError((e) {
        debugPrint('[AuthWrapper] chat restore skipped: $e');
      }),
    );
    unawaited(NotificationService.instance.start(currentUserId: userId));
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      // The native splash stays visible until session restoration is complete.
      // Keep this route blank so returning users never see signup or a loader.
      return const Scaffold(
        backgroundColor: Color(0xFF08090B),
        body: SizedBox.expand(),
      );
    }

    if (!_isLoggedIn) return const WelcomeView();

    if (_needsProfile) {
      return _profileSetupRoute();
    }

    return HomeScreen(
      currentUserId: _currentUserId!,
      initialProfileName: _currentUsername,
      initialPhone: _currentPhone,
      initialSavedContacts: _initialSavedContacts,
    );
  }
}
