import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';

void main() {
  final service = VirtualNumberService();

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
}
