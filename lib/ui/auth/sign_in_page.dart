import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/device_region_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/real_number_service.dart';
import 'package:wrytte/ui/auth/kface_intro_page.dart';
import 'package:wrytte/ui/auth/login_otp_page.dart';
import 'package:wrytte/ui/auth/otp_verification_page.dart';
import 'package:wrytte/ui/auth/active_device_login_page.dart';
import 'package:wrytte/ui/auth/widgets/auth_bottom_action.dart';
import 'package:wrytte/ui/auth/widgets/auth_page_header.dart';
import 'package:wrytte/ui/auth/country_picker_page.dart';
import 'package:wrytte/ui/auth/virtual_number_page.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/utils/country_phone_number.dart';
import 'package:wrytte/utils/countries.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final GlobalKey _identityInputKey = GlobalKey();
  final FocusNode _focusNode = FocusNode();
  final FocusNode _phoneFocusNode = FocusNode();
  final RealNumberService _realNumberService = RealNumberService();

  Country? _selectedCountry;
  bool _identityEntryStarted = false;
  bool _isValid = false;
  bool _isLoading = false;
  bool _isWrytteIdInput = false;
  bool _hasInvalidCountryCode = false;
  String? _errorMessage;

  bool get _canAttemptLogin =>
      _isWrytteIdInput
          ? _isValid
          : _selectedCountry != null &&
              !_hasInvalidCountryCode &&
              _phoneCtrl.text.replaceAll(RegExp(r'\D'), '').isNotEmpty;

  String _callingCode(Country country) {
    final metadataCode = CountryPhoneNumber.callingCodeForRegion(
      country.isoCode,
    );
    return metadataCode.isEmpty ? country.dialCode : metadataCode;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  Future<void> _pickCountry() async {
    final country = await Navigator.of(context).push<Country>(
      MaterialPageRoute(builder: (_) => const CountryPickerPage()),
    );
    if (!mounted || country == null) return;

    setState(() {
      _identityEntryStarted = true;
      _selectedCountry = country;
      _inputCtrl.text = '+${_callingCode(country)}';
      _phoneCtrl.clear();
      _isWrytteIdInput = false;
      _hasInvalidCountryCode = false;
      _isValid = false;
      _errorMessage = null;
    });
    _phoneFocusNode.requestFocus();
  }

  void _onCodeChanged(String value) {
    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    final isWrytteId = digits.startsWith('0');
    Country? detectedCountry;
    String? nationalDigitsFromSameField;
    var moveCaretToPhone = false;

    if (!isWrytteId && digits.isNotEmpty) {
      final exactMatches =
          countries.where((country) => _callingCode(country) == digits).toList()
            ..sort((a, b) {
              final aCanonical = a.dialCode == digits ? 0 : 1;
              final bCanonical = b.dialCode == digits ? 0 : 1;
              return aCanonical.compareTo(bCanonical);
            });
      final couldBeLongerCode = countries.any(
        (country) =>
            _callingCode(country).length > digits.length &&
            _callingCode(country).startsWith(digits),
      );

      if (exactMatches.isNotEmpty) {
        detectedCountry = exactMatches.first;
        moveCaretToPhone = !couldBeLongerCode;
      } else if (!couldBeLongerCode) {
        final shorterCodeMatches =
            countries
                .where((country) => digits.startsWith(_callingCode(country)))
                .toList()
              ..sort(
                (a, b) =>
                    _callingCode(b).length.compareTo(_callingCode(a).length),
              );
        if (shorterCodeMatches.isNotEmpty) {
          detectedCountry = shorterCodeMatches.first;
          final callingCodeDigits = _callingCode(detectedCountry);
          nationalDigitsFromSameField = digits.substring(
            callingCodeDigits.length,
          );
          moveCaretToPhone = true;
        }
      }
    }

    if (detectedCountry != null && nationalDigitsFromSameField != null) {
      _inputCtrl.value = TextEditingValue(
        text: '+${_callingCode(detectedCountry)}',
        selection: TextSelection.collapsed(
          offset: _callingCode(detectedCountry).length + 1,
        ),
      );
      _phoneCtrl.text = nationalDigitsFromSameField;
    }

    final isPossibleCodePrefix =
        !isWrytteId &&
        digits.isNotEmpty &&
        countries.any((country) => _callingCode(country).startsWith(digits));

    setState(() {
      _identityEntryStarted = digits.isNotEmpty;
      if (isWrytteId && !_isWrytteIdInput) {
        _phoneCtrl.clear();
        _selectedCountry = null;
      }
      _isWrytteIdInput = isWrytteId;
      _selectedCountry = isWrytteId ? null : detectedCountry;
      _hasInvalidCountryCode =
          !isWrytteId &&
          digits.isNotEmpty &&
          detectedCountry == null &&
          !isPossibleCodePrefix;
      _isValid =
          isWrytteId
              ? _isValidWrytteId(digits)
              : detectedCountry != null &&
                  CountryPhoneNumber.international(
                        _phoneCtrl.text,
                        detectedCountry.isoCode,
                      ) !=
                      null;
      _errorMessage = null;
    });

    if (!isWrytteId && detectedCountry != null && moveCaretToPhone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _isWrytteIdInput ||
            _selectedCountry?.isoCode != detectedCountry!.isoCode) {
          return;
        }
        _phoneFocusNode.requestFocus();
      });
    }
  }

  void _onPhoneChanged(String value) {
    setState(() {
      _isValid =
          _selectedCountry != null &&
          CountryPhoneNumber.international(value, _selectedCountry!.isoCode) !=
              null;
      _errorMessage = null;
    });
  }

  bool _isValidWrytteId(String digits) {
    return digits.startsWith('00') &&
        digits.length >= 10 &&
        digits.length <= 14;
  }

  void _onCodeTap() {
    if (_inputCtrl.text.isNotEmpty && !_inputCtrl.text.startsWith('+')) {
      _inputCtrl.text = '+${_inputCtrl.text}';
    }
    _inputCtrl.selection = TextSelection.collapsed(
      offset: _inputCtrl.text.length,
    );
  }

  Widget _buildCodeInput() => TextField(
    key: _identityInputKey,
    controller: _inputCtrl,
    focusNode: _focusNode,
    onTapOutside: (_) {
      _focusNode.unfocus();
      _phoneFocusNode.unfocus();
    },
    cursorColor: WrytteColors.primary,
    keyboardType: TextInputType.phone,
    inputFormatters: const [_CountryCodeOrIdFormatter()],
    style: WrytteTypography.authInput,
    decoration: const InputDecoration(
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      isDense: true,
      contentPadding: EdgeInsets.symmetric(vertical: 8),
    ),
    onChanged: _onCodeChanged,
    onTap: _onCodeTap,
  );

  Future<void> _goNext() async {
    if (_isLoading) return;
    String? validatedPhone;
    if (_isWrytteIdInput) {
      if (!_isValid) return;
    } else {
      final country = _selectedCountry;
      if (country == null || _hasInvalidCountryCode) return;
      final lengthStatus = CountryPhoneNumber.lengthStatus(
        _phoneCtrl.text,
        country.isoCode,
      );
      if (lengthStatus != PhoneNumberLengthStatus.valid) {
        _focusNode.unfocus();
        _phoneFocusNode.unfocus();
        final message = switch (lengthStatus) {
          PhoneNumberLengthStatus.tooShort =>
            'The phone number you entered is too short for ${country.name}.',
          PhoneNumberLengthStatus.tooLong =>
            'The phone number you entered is too long for ${country.name}.',
          PhoneNumberLengthStatus.invalidLength =>
            'The phone number you entered is invalid for ${country.name}.',
          PhoneNumberLengthStatus.valid => '',
        };
        await _showPhoneLengthDialog(message);
        return;
      }
      validatedPhone = CountryPhoneNumber.international(
        _phoneCtrl.text,
        country.isoCode,
      );
      if (validatedPhone == null) {
        _focusNode.unfocus();
        _phoneFocusNode.unfocus();
        await _showPhoneLengthDialog(
          'The phone number you entered is invalid for ${country.name}.',
        );
        return;
      }
    }

    final input =
        _isWrytteIdInput
            ? _inputCtrl.text.trim()
            : _selectedCountry == null
            ? ''
            : validatedPhone ?? '';

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (!mounted) return;

      final digits = input.replaceAll(RegExp(r'[^\d]'), '');
      if (digits.startsWith('00')) {
        if (!_isValidWrytteId(digits)) {
          throw const FormatException('Invalid Wrytte ID format');
        }
        final search = await AuthService.instance.searchWrytteIdForSignIn(
          digits,
        );
        if (!search.exists) {
          _focusNode.unfocus();
          // Stop the bottom action's loading indicator before displaying the
          // not-found prompt, which remains on top of this page.
          if (mounted) setState(() => _isLoading = false);
          await _showWrytteIdUnavailableDialog();
          return;
        }
        _focusNode.unfocus();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted) return;
        if (search.kface) {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder:
                  (_) =>
                      KFaceIntroPage(wrytteId: digits, userId: search.userId),
            ),
          );
        } else if (search.activeDevice) {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder:
                  (_) => ActiveDeviceLoginPage(
                    account: digits,
                    userId: search.userId,
                  ),
            ),
          );
        } else {
          throw const FormatException(
            'No login method is available for this account',
          );
        }
        return;
      }
      final phone = CountryPhoneNumber.normalizeInternational(input);
      if (phone == null) {
        throw const FormatException('Invalid international phone number');
      }

      final lookup = await _realNumberService.searchPhoneAuthMethods(phone);
      if (!mounted) return;
      if (!lookup.exists) {
        await _realNumberService.sendSmsCode(phone);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder:
                (_) => OtpVerificationPage(
                  phoneNumber: phone,
                  isSignInFlow: false,
                ),
          ),
        );
        return;
      }
      if (lookup.kface) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder:
                (_) => KFaceIntroPage(wrytteId: phone, userId: lookup.userId),
          ),
        );
      } else if (lookup.activeDevice) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder:
                (_) => ActiveDeviceLoginPage(
                  account: phone,
                  userId: lookup.userId,
                ),
          ),
        );
      } else if (lookup.sms) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder:
                (_) => LoginOtpPage(phoneNumber: phone, userId: lookup.userId),
          ),
        );
      } else {
        throw const FormatException(
          'No login method is available for this account',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showPhoneLengthDialog(String message) async {
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => Dialog(
            backgroundColor: const Color(0xFF23262C),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('OK'),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _showWrytteIdUnavailableDialog() async {
    final shouldSignUp = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => Dialog(
            backgroundColor: const Color(0xFF23262C),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'This Wrytte ID is not registered.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Divider(height: 1, color: Colors.white12),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: OutlinedButton(
                            onPressed:
                                () => Navigator.pop(dialogContext, false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Color(0xFF4A4D55)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: ElevatedButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4DA3FF),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('Sign up'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
    );
    if (!mounted || shouldSignUp != true) return;

    final regionCode = await DeviceRegionService.detectOnce();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => VirtualNumberPage(regionCode: regionCode),
      ),
    );
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _phoneCtrl.dispose();
    _focusNode.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WrytteColors.background,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: AuthBottomAction(
              label: 'Next',
              busy: _isLoading,
              onPressed: _canAttemptLogin ? _goNext : null,
              focusNodes: [_focusNode, _phoneFocusNode],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AuthPageHeader(title: 'Log in'),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const AuthPageSubtitle(
                            child: SizedBox(
                              width: double.infinity,
                              child: Text(
                                'Enter your Wrytte ID or Phone number to log in',
                                textAlign: TextAlign.center,
                                style: WrytteTypography.authSubtitle,
                              ),
                            ),
                          ),
                          const SizedBox(height: 26),
                          if (!_identityEntryStarted)
                            Material(
                              color: Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(36),
                                side: const BorderSide(
                                  color: WrytteColors.surfaceRaised,
                                  width: 1.5,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: [
                                    const Text(
                                      '+',
                                      style: WrytteTypography.authInput,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: TextField(
                                        key: _identityInputKey,
                                        controller: _inputCtrl,
                                        focusNode: _focusNode,
                                        onTapOutside: (_) {
                                          _focusNode.unfocus();
                                          _phoneFocusNode.unfocus();
                                        },
                                        cursorColor: WrytteColors.primary,
                                        keyboardType: TextInputType.phone,
                                        inputFormatters: const [
                                          _CountryCodeOrIdFormatter(),
                                        ],
                                        style: WrytteTypography.authInput,
                                        decoration: InputDecoration(
                                          hintText: 'Wrytte ID or Phone number',
                                          hintStyle: WrytteTypography.authInput
                                              .copyWith(
                                                color: WrytteColors.textMuted,
                                              ),
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          isDense: true,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                vertical: 8,
                                              ),
                                        ),
                                        onChanged: _onCodeChanged,
                                        onTap: _onCodeTap,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            Material(
                              key: const ValueKey('login-identity-card'),
                              color: Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(28),
                                side: const BorderSide(
                                  color: WrytteColors.surfaceRaised,
                                  width: 1.5,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    key: const ValueKey(
                                      'login-identity-country',
                                    ),
                                    onTap:
                                        _isWrytteIdInput ? null : _pickCountry,
                                    leading:
                                        _isWrytteIdInput
                                            ? Image.asset(
                                              'assets/images/wrytte_id_signup_icon_128.png',
                                              width: 27,
                                              height: 27,
                                              fit: BoxFit.contain,
                                              filterQuality: FilterQuality.high,
                                            )
                                            : null,
                                    title: Text(
                                      _isWrytteIdInput
                                          ? 'Wrytte ID'
                                          : _hasInvalidCountryCode
                                          ? 'Invalid country code'
                                          : _selectedCountry == null
                                          ? 'Country'
                                          : '${_selectedCountry!.flag} ${_selectedCountry!.name}',
                                      style: WrytteTypography.authInput,
                                    ),
                                    trailing: const Icon(
                                      Icons.chevron_right,
                                      color: WrytteColors.textPrimary,
                                      size: 22,
                                    ),
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    minLeadingWidth:
                                        _isWrytteIdInput ? 27 : null,
                                    horizontalTitleGap:
                                        _isWrytteIdInput ? 10 : null,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Divider(
                                      color: Colors.white12,
                                      height: 1,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Flexible(
                                          flex:
                                              _selectedCountry != null &&
                                                      !_isWrytteIdInput
                                                  ? 0
                                                  : 1,
                                          fit:
                                              _selectedCountry != null &&
                                                      !_isWrytteIdInput
                                                  ? FlexFit.loose
                                                  : FlexFit.tight,
                                          child: ConstrainedBox(
                                            constraints:
                                                BoxConstraints.tightFor(
                                                  width:
                                                      _selectedCountry !=
                                                                  null &&
                                                              !_isWrytteIdInput
                                                          ? 70
                                                          : null,
                                                ),
                                            child: _buildCodeInput(),
                                          ),
                                        ),
                                        if (_selectedCountry != null &&
                                            !_isWrytteIdInput) ...[
                                          Container(
                                            height: 22,
                                            width: 1.5,
                                            color: WrytteColors.surfaceRaised,
                                            margin: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                          ),
                                          Expanded(
                                            child: TextField(
                                              controller: _phoneCtrl,
                                              focusNode: _phoneFocusNode,
                                              keyboardType: TextInputType.phone,
                                              inputFormatters: [
                                                CountryPhoneNumberInputFormatter(
                                                  _selectedCountry!.isoCode,
                                                ),
                                              ],
                                              cursorColor: WrytteColors.primary,
                                              style: WrytteTypography.authInput,
                                              decoration: InputDecoration(
                                                hintText: 'Phone number',
                                                hintStyle: WrytteTypography
                                                    .authInput
                                                    .copyWith(
                                                      color:
                                                          WrytteColors
                                                              .textMuted,
                                                    ),
                                                border: InputBorder.none,
                                                enabledBorder: InputBorder.none,
                                                focusedBorder: InputBorder.none,
                                                isDense: true,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 8,
                                                    ),
                                              ),
                                              onChanged: _onPhoneChanged,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Center(
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              children: [
                                Text(
                                  'Create new account. ',
                                  style: WrytteTypography.authBody,
                                ),
                                GestureDetector(
                                  onTap:
                                      () => Navigator.pushReplacementNamed(
                                        context,
                                        '/auth',
                                      ),
                                  child: Text(
                                    'Sign up',
                                    style: WrytteTypography.authBody.copyWith(
                                      color: WrytteColors.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CountryCodeOrIdFormatter extends TextInputFormatter {
  const _CountryCodeOrIdFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return TextEditingValue.empty;
    if (digits.startsWith('0')) {
      final limitedDigits = digits.length > 14 ? digits.substring(0, 14) : digits;
      final body =
          limitedDigits.length > 2 ? limitedDigits.substring(2) : '';
      final formatted = body.isEmpty ? '00' : '00 $body';
      return TextEditingValue(
        text: '+$formatted',
        selection: TextSelection.collapsed(offset: 1 + formatted.length),
        composing: TextRange.empty,
      );
    }

    final limitedDigits = digits.length > 4 ? digits.substring(0, 4) : digits;
    final cursorOffset = newValue.selection.extentOffset.clamp(
      0,
      newValue.text.length,
    );
    final digitsBeforeCursor = newValue.text
        .substring(0, cursorOffset)
        .replaceAll(RegExp(r'[^0-9]'), '')
        .length
        .clamp(0, 4);

    return TextEditingValue(
      text: '+$limitedDigits',
      selection: TextSelection.collapsed(offset: 1 + digitsBeforeCursor),
      composing: TextRange.empty,
    );
  }
}
