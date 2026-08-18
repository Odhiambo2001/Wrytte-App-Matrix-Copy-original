import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/utils/country_phone_number.dart';

void main() {
  group('CountryPhoneNumber', () {
    test('uses US metadata to format punctuation and normalize E.164', () {
      expect(
        CountryPhoneNumber.formatNational('(202) 555-0119', 'US'),
        '(202) 555-0119',
      );
      expect(
        CountryPhoneNumber.international('202 555 0119', 'US'),
        '+12025550119',
      );
    });

    test('uses French metadata and removes the national trunk prefix', () {
      expect(
        CountryPhoneNumber.formatNational('06 55 57 05 76', 'FR'),
        '6 55 57 05 76',
      );
      expect(
        CountryPhoneNumber.international('06-55-57-05-76', 'FR'),
        '+33655570576',
      );
    });

    test('accepts a valid NANP region when Canada and US share +1', () {
      expect(
        CountryPhoneNumber.international('(412) 448-9326', 'CA'),
        '+14124489326',
      );
    });

    test('formats a stored international number for profile display', () {
      expect(
        CountryPhoneNumber.formatInternationalDisplay('13107353765'),
        '+1 (310) 735-3765',
      );
      expect(
        CountryPhoneNumber.formatInternationalDisplay('33749542126'),
        '+33 7 49 54 21 26',
      );
    });

    test('formats an international number progressively while typing', () {
      final formatter = InternationalPhoneNumberInputFormatter();
      var value = const TextEditingValue();
      for (final input in <String>[
        '2',
        '25',
        '254',
        '2547',
        '25471',
        '254712',
      ]) {
        value = formatter.formatEditUpdate(
          value,
          TextEditingValue(
            text: input,
            selection: TextSelection.collapsed(offset: input.length),
          ),
        );
      }
      expect(value.text, '254 712');
    });

    test('formats a Wrytte ID progressively in three-digit groups', () {
      final formatter = InternationalPhoneNumberInputFormatter();
      final value = formatter.formatEditUpdate(
        const TextEditingValue(),
        const TextEditingValue(
          text: '00700297347',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      expect(value.text, '00 700 297 347');
    });

    test('formats and limits a US Wrytte ID resolved from prefix 212', () {
      final formatter = InternationalPhoneNumberInputFormatter();
      final value = formatter.formatEditUpdate(
        const TextEditingValue(),
        const TextEditingValue(
          text: '002125550123999',
          selection: TextSelection.collapsed(offset: 15),
        ),
      );
      expect(value.text, '00 212 555 0123');
    });

    test('formats and limits a Kenyan Wrytte ID resolved from prefix 710', () {
      final formatter = InternationalPhoneNumberInputFormatter();
      final value = formatter.formatEditUpdate(
        const TextEditingValue(),
        const TextEditingValue(
          text: '0071012345699',
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      expect(value.text, '00 710 123 456');
    });

    test('rejects incomplete and impossible numbers', () {
      expect(CountryPhoneNumber.international('123', 'US'), isNull);
      expect(CountryPhoneNumber.international('', 'US'), isNull);
      expect(
        CountryPhoneNumber.international('+33 6 55 57 05 76', 'US'),
        isNull,
      );
    });

    test('distinguishes country-specific short and long numbers', () {
      expect(
        CountryPhoneNumber.lengthStatus('7775856', 'US'),
        PhoneNumberLengthStatus.tooShort,
      );
      expect(
        CountryPhoneNumber.lengthStatus('777585696988885', 'US'),
        PhoneNumberLengthStatus.tooLong,
      );
      expect(
        CountryPhoneNumber.lengthStatus('3107353765', 'US'),
        PhoneNumberLengthStatus.valid,
      );
    });
  });
}
