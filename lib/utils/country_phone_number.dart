import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/wrytte_library.dart';
import 'package:phone_numbers_parser/metadata.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

enum PhoneNumberLengthStatus { valid, tooShort, tooLong, invalidLength }

/// Country-aware parsing and formatting backed by `phone_numbers_parser`.
class CountryPhoneNumber {
  const CountryPhoneNumber._();

  static final Map<String, String> _callingCodesByRegion = {};

  static IsoCode? isoCodeFromAlpha2(String alpha2) {
    return isoCodeConversionMap[alpha2.toUpperCase()];
  }

  static String callingCodeForRegion(String regionCode) {
    final isoCode = isoCodeFromAlpha2(regionCode);
    if (isoCode == null) return '';
    return _callingCodesByRegion.putIfAbsent(
      isoCode.name,
      () => PhoneNumber(isoCode: isoCode, nsn: '').countryCode,
    );
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
    if (number == null) {
      final isoCode = isoCodeFromAlpha2(countryAlpha2);
      if (isoCode != null) {
        final callingCode = PhoneNumber(isoCode: isoCode, nsn: '').countryCode;
        final digitCount = input.replaceAll(RegExp(r'[^\d]'), '').length;
        if (digitCount + callingCode.length > 15) {
          return PhoneNumberLengthStatus.tooLong;
        }
        final possibleLengths = _possibleNationalLengths(isoCode);
        if (possibleLengths.isNotEmpty) {
          final minimumLength = possibleLengths.reduce((a, b) => a < b ? a : b);
          final maximumLength = possibleLengths.reduce((a, b) => a > b ? a : b);
          if (digitCount < minimumLength) {
            return PhoneNumberLengthStatus.tooShort;
          }
          if (digitCount > maximumLength) {
            return PhoneNumberLengthStatus.tooLong;
          }
        }
      }
      return PhoneNumberLengthStatus.invalidLength;
    }
    if (number.countryCode.length + number.nsn.length > 15) {
      return PhoneNumberLengthStatus.tooLong;
    }

    final possibleLengths = _possibleNationalLengths(number.isoCode);
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

  static Set<int> _possibleNationalLengths(IsoCode isoCode) {
    final metadata = metadataLenghtsByIsoCode[isoCode];
    if (metadata == null) return {};
    // These auth fields verify by SMS, so use mobile numbering lengths where
    // the country metadata provides them. Other categories, such as toll-free,
    // can have different lengths and must not make a mobile number seem valid.
    if (metadata.mobile.isNotEmpty) {
      return metadata.mobile.where((length) => length > 0).toSet();
    }
    return <int>{
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
      return '+${number.countryCode} ${number.formatNsn()}';
    } on PhoneNumberException {
      return international;
    } on FormatException {
      return international;
    }
  }

  /// Normalizes a complete international number to E.164.
  static String? normalizeInternational(String input) {
    final digits = input.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return null;
    try {
      final number = PhoneNumber.parse('+$digits');
      return number.isValid() ? number.international : null;
    } on PhoneNumberException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Formats a phone number entered with its international calling code.
/// Incomplete input and Wrytte IDs beginning with +00 remain editable.
class InternationalPhoneNumberInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return const TextEditingValue();

    final formatted =
        digits.startsWith('00')
            ? _formatWrytteId(digits)
            : _withoutLeadingPlus(
              CountryPhoneNumber.formatInternationalDisplay('+$digits'),
            );
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  static String _withoutLeadingPlus(String value) =>
      value.startsWith('+') ? value.substring(1) : value;

  static String _formatWrytteId(String digits) {
    final suppliedBody = digits.length > 2 ? digits.substring(2) : '';
    final body = suppliedBody.substring(0, suppliedBody.length.clamp(0, 12));
    final rule = WrytteLibrary.resolvePrefix(body);
    final groups = <String>['00'];
    final sizes =
        rule == null
            ? List<int>.filled((body.length / 3).ceil(), 3)
            : rule.format.split(' ').map(int.parse);
    var offset = 0;
    for (final size in sizes) {
      final end = (offset + size).clamp(0, body.length);
      if (end > offset) groups.add(body.substring(offset, end));
      offset = end;
      if (offset >= body.length) break;
    }
    if (offset < body.length) groups.add(body.substring(offset));
    return groups.join(' ');
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

    // Let backspace remove grouping punctuation instead of immediately
    // inserting it again and trapping the cursor beside a bracket.
    if (newValue.text.length < oldValue.text.length) return newValue;

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
