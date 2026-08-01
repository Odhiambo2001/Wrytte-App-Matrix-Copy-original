import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

/// Country-aware parsing and formatting backed by `phone_numbers_parser`.
class CountryPhoneNumber {
  const CountryPhoneNumber._();

  static IsoCode? isoCodeFromAlpha2(String alpha2) {
    return isoCodeConversionMap[alpha2.toUpperCase()];
  }

  static PhoneNumber? tryParse(String input, String countryAlpha2) {
    final isoCode = isoCodeFromAlpha2(countryAlpha2);
    if (isoCode == null || input.trim().isEmpty) return null;

    final compactInput = input.replaceAll(RegExp(r'[\s().-]'), '');
    final selectedCallingCode =
        PhoneNumber(isoCode: isoCode, nsn: '').countryCode;
    if (compactInput.startsWith('+') &&
        !compactInput.startsWith('+$selectedCallingCode')) {
      return null;
    }

    try {
      return PhoneNumber.parse(input, destinationCountry: isoCode);
    } on PhoneNumberException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static String? international(String input, String countryAlpha2) {
    final number = tryParse(input, countryAlpha2);
    return number?.isValid() == true ? number!.international : null;
  }

  static String formatNational(String input, String countryAlpha2) {
    final number = tryParse(input, countryAlpha2);
    if (number == null) return input;

    try {
      return number.formatNsn();
    } on PhoneNumberException {
      return input;
    }
  }
}

/// Re-formats complete number groups while retaining useful partial input.
class CountryPhoneNumberInputFormatter extends TextInputFormatter {
  CountryPhoneNumberInputFormatter(this.countryAlpha2);

  final String countryAlpha2;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    if (raw.isEmpty) return newValue;

    // Keep the phone keyboard characters users commonly paste/type, but do not
    // merge extensions or other text into the subscriber number.
    if (RegExp(r'[^0-9+()\-\s.]').hasMatch(raw)) return oldValue;

    final formatted = CountryPhoneNumber.formatNational(raw, countryAlpha2);
    if (formatted == raw) return newValue;

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
