import 'package:wrytte/domain/models/auth_flow.dart';

abstract final class AppRoutes {
  static const startup = '/';
  static const welcome = '/welcome';
  static const authEntry = '/auth';
  static const countryPicker = '/auth/country';
  static const wrytteId = '/auth/wrytte-id';
  static const kface = '/auth/kface';
  static const profileSetup = '/auth/profile';
  static const legal = '/legal';
  static const home = '/home';
  static const profile = '/profile';
  static const chatPreview = '/chat/preview';

  static String phone(AuthFlow flow) => '/auth/phone/${flow.routeValue}';

  static String otp(AuthFlow flow, String phoneNumber) {
    return Uri(
      path: '/auth/otp/${flow.routeValue}',
      queryParameters: {'phone': phoneNumber},
    ).toString();
  }
}
