import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/services/auth/wrytte_library.dart';

void main() {
  final service = VirtualNumberService(candidateExists: (_) async => false);

  test('uses phone metadata to resolve regional Wrytte ID prefixes', () {
    expect(service.callingCodeForRegion('KE'), '254');
    expect(service.callingCodeForRegion('FR'), '33');
    expect(service.callingCodeForRegion('US'), '1');
  });

  test('formats a Kenyan Wrytte ID as +00 using Kenyan grouping', () {
    final formatted = service.formatWrytteId('00748630243', regionCode: 'KE');

    expect(formatted, '+00 748 630 243');
    expect(formatted, isNot(contains(RegExp(r'[()\-]'))));
  });

  test('formats a US Wrytte ID as +00 using spaces only', () {
    final formatted = service.formatWrytteId('002125550123', regionCode: 'US');

    expect(formatted, '+00 212 555 0123');
    expect(formatted, isNot(contains(RegExp(r'[()\-]'))));
  });

  test('Wrytte library resolves formats and supplied prefixes by ISO', () {
    expect(WrytteLibrary.forRegion('KE')?.format, '3 3 3');
    expect(WrytteLibrary.prefixesFor('KE'), ['700', '710', '720']);
    expect(WrytteLibrary.forRegion('US')?.format, '3 3 4');
    expect(WrytteLibrary.prefixesFor('US'), contains('212'));
    expect(WrytteLibrary.prefixesFor('NZ'), contains('21'));
    expect(WrytteLibrary.resolvePrefix('2125550123')?.isoCode, 'US');
    expect(WrytteLibrary.resolvePrefix('700297347')?.isoCode, 'KE');
    expect(WrytteLibrary.resolvePrefix('710297347')?.isoCode, 'KE');
    expect(WrytteLibrary.resolvePrefix('720297347')?.isoCode, 'KE');
    expect(
      WrytteLibrary.rules.values
          .where((rule) => rule.format.isNotEmpty)
          .every((rule) => RegExp(r'^\d+(?: \d+)*$').hasMatch(rule.format)),
      isTrue,
    );
  });

  test(
    'creates a non-repeated Kenyan candidate with a 15-minute lifetime',
    () async {
      SharedPreferences.setMockInitialValues({});

      final candidate = await service.getAvailableVpn(regionCode: 'KE');
      final body = candidate.number.substring(2);

      expect(candidate.number, startsWith('00'));
      expect(candidate.number.length, 11);
      expect(body.length, 9);
      expect(['700', '710', '720'], contains(body.substring(0, 3)));
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

  test('refresh generates a different Wrytte ID', () async {
    SharedPreferences.setMockInitialValues({});

    final first = await service.getAvailableVpn(regionCode: 'KE');
    final refreshed = await service.refreshAvailableVpn(regionCode: 'KE');

    expect(refreshed.number, isNot(first.number));
    expect(refreshed.number, startsWith('00'));
  });

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
    expect(candidate.number, startsWith('00'));
    expect(candidate.number.substring(2), searched.last.substring(1));
  });
}
