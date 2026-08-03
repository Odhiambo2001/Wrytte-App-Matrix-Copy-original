import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';

void main() {
  final service = VirtualNumberService(candidateExists: (_) async => false);

  test('uses phone metadata to resolve regional Wrytte ID prefixes', () {
    expect(service.callingCodeForRegion('KE'), '254');
    expect(service.callingCodeForRegion('FR'), '33');
    expect(service.callingCodeForRegion('US'), '1');
  });

  test('formats a Wrytte ID with spaces only after the regional prefix', () {
    final formatted = service.formatWrytteId('254123456789', regionCode: 'KE');

    expect(formatted, '+254 123 456 789');
    expect(formatted, isNot(contains(RegExp(r'[()\-]'))));
  });

  test(
    'creates a non-repeated Kenyan candidate with a 15-minute lifetime',
    () async {
      SharedPreferences.setMockInitialValues({});

      final candidate = await service.getAvailableVpn(regionCode: 'KE');
      final body = candidate.number.substring(3);

      expect(candidate.number, startsWith('254'));
      expect(candidate.number.length, 12);
      expect(body.length, 9);
      expect(body.split('').toSet().length, greaterThan(1));
      expect(
        candidate.expiresAt.difference(DateTime.now()).inMinutes,
        inInclusiveRange(14, 15),
      );
    },
  );

  test(
    'reuses the live local candidate instead of generating another',
    () async {
      SharedPreferences.setMockInitialValues({});

      final first = await service.getAvailableVpn(regionCode: 'FR');
      final second = await service.getAvailableVpn(regionCode: 'FR');

      expect(first.number.length, 11);
      expect(first.number.substring(2).length, 9);
      expect(second.number, first.number);
      expect(
        second.expiresAt.millisecondsSinceEpoch,
        first.expiresAt.millisecondsSinceEpoch,
      );
    },
  );

  test('sends W plus suffix only and retries a taken candidate', () async {
    SharedPreferences.setMockInitialValues({});
    final searched = <String>[];
    final checkingService = VirtualNumberService(
      candidateExists: (value) async {
        searched.add(value);
        return searched.length == 1;
      },
    );

    final candidate = await checkingService.getAvailableVpn(regionCode: 'KE');

    expect(searched, hasLength(2));
    expect(
      searched.every((value) => RegExp(r'^W\d{9}$').hasMatch(value)),
      isTrue,
    );
    expect(candidate.number, startsWith('254'));
    expect(candidate.number.substring(3), searched.last.substring(1));
  });
}
