import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/metadata.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

enum PhoneNumberLengthStatus { valid, tooShort, tooLong, invalidLength }

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
    if (number == null) return null;
    if (number.isValid()) return number.international;

    // Some calling codes belong to several regions. For example, Canada, the
    // US, and multiple Caribbean territories all use +1. Parsing a local +1
    // number strictly as Canada can therefore reject a valid US area code.
    // Reparse the normalized international value so the package can infer the
    // correct region, while retaining the calling-code guard in tryParse().
    try {
      final inferred = PhoneNumber.parse(number.international);
      return inferred.isValid() ? inferred.international : null;
    } on PhoneNumberException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Compares the parsed national number with every length supported by the
  /// selected region. E.164 additionally limits the complete number to 15
  /// digits, including its country calling code.
  static PhoneNumberLengthStatus lengthStatus(
    String input,
    String countryAlpha2,
  ) {
    final number = tryParse(input, countryAlpha2);
    if (number == null) return PhoneNumberLengthStatus.invalidLength;
    if (number.countryCode.length + number.nsn.length > 15) {
      return PhoneNumberLengthStatus.tooLong;
    }

    final metadata = metadataLenghtsByIsoCode[number.isoCode];
    if (metadata == null) return PhoneNumberLengthStatus.invalidLength;
    final possibleLengths = <int>{
      ...metadata.mobile,
      ...metadata.fixedLine,
      ...metadata.voip,
      ...metadata.tollFree,
      ...metadata.premiumRate,
      ...metadata.sharedCost,
      ...metadata.personalNumber,
      ...metadata.uan,
      ...metadata.pager,
      ...metadata.voiceMail,
    }..removeWhere((length) => length <= 0);
    if (possibleLengths.isEmpty) {
      return number.isValidLength()
          ? PhoneNumberLengthStatus.valid
          : PhoneNumberLengthStatus.invalidLength;
    }

    final length = number.nsn.length;
    if (length < possibleLengths.reduce((a, b) => a < b ? a : b)) {
      return PhoneNumberLengthStatus.tooShort;
    }
    if (length > possibleLengths.reduce((a, b) => a > b ? a : b)) {
      return PhoneNumberLengthStatus.tooLong;
    }
    return possibleLengths.contains(length)
        ? PhoneNumberLengthStatus.valid
        : PhoneNumberLengthStatus.invalidLength;
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

  /// Formats a stored international number for display, keeping its calling
  /// code separate from the region-specific national grouping.
  static String formatInternationalDisplay(String input) {
    final compact = input.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (compact.isEmpty) return '';
    final international = compact.startsWith('+') ? compact : '+$compact';

    try {
      final number = PhoneNumber.parse(international);
      if (!number.isValid()) return international;
      return '+${number.countryCode} ${number.formatNsn()}';
    } on PhoneNumberException {
      return international;
    } on FormatException {
      return international;
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
