import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:wrytte/ui/auth/auth_entry_screen.dart';
import 'package:wrytte/ui/auth/welcome_view.dart';
import 'package:wrytte/ui/auth/email_verification_page.dart';
import 'package:wrytte/ui/auth/login_email_verification_page.dart';
import 'package:wrytte/ui/auth/phone_auth_page.dart';
import 'package:wrytte/ui/auth/otp_verification_page.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/auth/sign_in_page.dart';
import 'package:wrytte/ui/auth/virtual_number_page.dart';

import 'package:wrytte/ui/screens/home_screen.dart';
import 'package:wrytte/ui/screens/terms_privacy_page.dart';
import 'package:wrytte/ui/widgets/theme_wrapper.dart';

import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/face/android_tflite_image_session.dart';

import 'firebase_options.dart';
import 'core/theme.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

const _systemBarColor = Colors.transparent;

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

Future<void> main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  await Hive.initFlutter();

  await _ensureFirebaseInitialized();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Do not make the first scanner visit compile the GPU delegate. This is
  // deliberately unawaited so the app remains responsive while the splash and
  // normal authentication flow are displayed.
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

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

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
}

class WrytteApp extends StatelessWidget {
  const WrytteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wrytte',
      debugShowCheckedModeBanner: false,
      theme: WrytteTheme.lightTheme,
      home: const ThemeWrapper(child: AuthWrapper()),
      routes: {
        '/welcome': (context) => const ThemeWrapper(child: WelcomeView()),
        '/auth': (context) => const ThemeWrapper(child: AuthEntryScreen()),
        '/auth_entry_screen':
            (context) => const ThemeWrapper(child: AuthEntryScreen()),

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

        '/add_profile':
            (context) =>
                const ThemeWrapper(child: AddProfilePage(isNewUser: true)),

        '/home': (context) => const ThemeWrapper(child: AuthWrapper()),

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
            .hydrateLocalConversations(syncReadMarkers: false)
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

      FlutterNativeSplash.remove();
    } catch (e) {
      debugPrint('[AuthWrapper] Session check error: $e');
      if (mounted) {
        setState(() {
          _isLoggedIn = false;
          _checking = false;
        });
      }
      FlutterNativeSplash.remove();
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
      return const Scaffold(
        backgroundColor: Color(0xFF08090B),
        body: SizedBox.shrink(),
      );
    }

    if (!_isLoggedIn) return const WelcomeView();

    if (_needsProfile) {
      return const AddProfilePage(isNewUser: false);
    }

    return HomeScreen(
      currentUserId: _currentUserId!,
      initialProfileName: _currentUsername,
      initialPhone: _currentPhone,
      initialSavedContacts: _initialSavedContacts,
    );
  }
}
