import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/real_number_service.dart';
import 'package:wrytte/ui/auth/country_picker_page.dart';
import 'package:wrytte/ui/auth/active_device_login_page.dart';
import 'package:wrytte/ui/auth/kface_intro_page.dart';
import 'package:wrytte/ui/auth/widgets/auth_bottom_action.dart';
import 'package:wrytte/ui/auth/widgets/auth_page_header.dart';
import 'package:wrytte/ui/screens/terms_privacy_page.dart';
import 'package:wrytte/core/theme.dart';
import 'package:wrytte/utils/countries.dart';
import 'package:wrytte/utils/country_phone_number.dart';
import 'otp_verification_page.dart';

class PhoneAuthPage extends StatefulWidget {
  final bool isSignInFlow;

  const PhoneAuthPage({super.key, this.isSignInFlow = false});

  @override
  State<PhoneAuthPage> createState() => _PhoneAuthPageState();
}

class _PhoneAuthPageState extends State<PhoneAuthPage> {
  Country? _selectedCountry;

  final TextEditingController _codeCtrl = TextEditingController();
  final TextEditingController _numberCtrl = TextEditingController();

  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _numberFocusNode = FocusNode();

  final RealNumberService _realNumberService = RealNumberService();

  bool _isSending = false;
  Future<void>? _sendCodeFuture;
  bool _showDivider = false;
  bool _isAutoFilling = false;
  bool _hasInvalidCountryCode = false;

  /// Valid, normalized international number (for example +254712345678).
  String? get _fullPhone =>
      _selectedCountry == null
          ? null
          : CountryPhoneNumber.international(
            _numberCtrl.text,
            _selectedCountry!.isoCode,
          );

  /// Validation
  bool get _isValid => _fullPhone != null;
  bool get _canAttemptVerification =>
      _codeCtrl.text.replaceAll(RegExp(r'[^\d]'), '').isNotEmpty &&
      _numberCtrl.text.trim().isNotEmpty;

  /// Pick country
  Future<void> _pickCountry() async {
    final result = await Navigator.of(context).push<Country>(
      MaterialPageRoute(builder: (_) => const CountryPickerPage()),
    );

    if (result != null) {
      setState(() {
        _selectedCountry = result;
        _hasInvalidCountryCode = false;
        _codeCtrl.text = '+${result.dialCode}'; // Keep the plus sign
        _showDivider = true;
        _numberCtrl.clear();
      });

      // Move focus to number field after country selection
      _numberFocusNode.requestFocus();
    }
  }

  /// Detect country from typed code (Telegram behavior)
  void _detectCountryFromCode(String value) {
    if (_isAutoFilling) return;

    // Ensure plus sign is always present
    if (!value.startsWith('+')) {
      _codeCtrl.text = '+$value';
      _codeCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeCtrl.text.length),
      );
      return;
    }

    final codeWithoutPlus = value.substring(1).replaceAll(RegExp(r'[^\d]'), '');
    Country? detectedCountry;
    for (final country in countries) {
      if (country.dialCode == codeWithoutPlus) {
        detectedCountry = country;
        break;
      }
    }

    if (detectedCountry == null && _numberCtrl.text.isNotEmpty) {
      final digits = _numberCtrl.text.replaceAll(RegExp(r'[^\d]'), '');
      _numberCtrl.value = TextEditingValue(
        text: digits,
        selection: TextSelection.collapsed(offset: digits.length),
      );
    }

    setState(() {
      _selectedCountry = detectedCountry;
      _hasInvalidCountryCode =
          detectedCountry == null && codeWithoutPlus.isNotEmpty;
      _showDivider = codeWithoutPlus.isNotEmpty;
    });

    if (detectedCountry != null && !_isAutoFilling) {
      _isAutoFilling = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        _numberFocusNode.requestFocus();
        _isAutoFilling = false;
      });
    }
  }

  /// Handle code field focus and cursor position
  void _onCodeFieldTap() {
    // Ensure cursor is after the plus sign
    if (_codeCtrl.text.isEmpty) {
      _codeCtrl.text = '+';
      _codeCtrl.selection = TextSelection.fromPosition(TextPosition(offset: 1));
    } else if (!_codeCtrl.text.startsWith('+')) {
      _codeCtrl.text = '+${_codeCtrl.text}';
      _codeCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeCtrl.text.length),
      );
    } else {
      // Cursor should be after the plus sign
      _codeCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeCtrl.text.length),
      );
    }
  }

  /// Start verification
  Future<void> _startVerification() async {
    if (_isSending || _sendCodeFuture != null) return;
    if (_hasInvalidCountryCode || _selectedCountry == null) {
      await _showInvalidCountryCodeDialog();
      return;
    }
    if (!_isValid) {
      await _showInvalidPhoneDialog();
      return;
    }

    setState(() => _isSending = true);

    final future = _sendVerificationCode();
    _sendCodeFuture = future;
    try {
      await future;
    } finally {
      _sendCodeFuture = null;
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _showInvalidPhoneDialog() async {
    final country = _selectedCountry;
    if (country == null) return;

    final lengthStatus = CountryPhoneNumber.lengthStatus(
      _numberCtrl.text,
      country.isoCode,
    );
    final message = switch (lengthStatus) {
      PhoneNumberLengthStatus.tooShort =>
        'The phone number you entered has an invalid length for ${country.name}.',
      PhoneNumberLengthStatus.tooLong =>
        'The phone number you entered is too long for ${country.name}.',
      PhoneNumberLengthStatus.invalidLength =>
        'The phone number you entered has an invalid length for ${country.name}.',
      PhoneNumberLengthStatus.valid =>
        'The phone number you entered is not valid for ${country.name}.',
    };

    await _showValidationDialog(message);
  }

  Future<void> _showInvalidCountryCodeDialog() async {
    final code = _codeCtrl.text.replaceAll(RegExp(r'[^\d]'), '');
    await _showValidationDialog(
      'Country code +$code is invalid. Please correct it.',
    );
  }

  Future<void> _showValidationDialog(String message) async {
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
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.only(
                          bottomLeft: Radius.circular(14),
                          bottomRight: Radius.circular(14),
                        ),
                      ),
                    ),
                    child: const Text('OK'),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _sendVerificationCode() async {
    try {
      final phone = _fullPhone;
      if (phone == null) return;

      // The signup entry point also supports returning users. Search first so
      // an existing number receives the sign-in SMS flow instead of being
      // blocked with a "use Log In" message.
      final lookup = await _realNumberService.searchPhoneAuthMethods(phone);
      final existingAccount = lookup.exists;
      if (existingAccount && lookup.kface) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder:
                (_) => KFaceIntroPage(wrytteId: phone, userId: lookup.userId),
          ),
        );
        return;
      }
      if (existingAccount && lookup.activeDevice) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder:
                (_) => ActiveDeviceLoginPage(
                  account: phone,
                  userId: lookup.userId,
                ),
          ),
        );
        return;
      }
      if (existingAccount) {
        if (!lookup.sms) {
          throw Exception(
            'No verification method is available for this account.',
          );
        }
        await _realNumberService.sendLoginSmsCode(phone);
      } else {
        if (widget.isSignInFlow) {
          throw Exception('Phone account not found.');
        }
        await _realNumberService.sendSmsCode(phone);
      }

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => OtpVerificationPage(
                phoneNumber: phone,
                isSignInFlow: existingAccount,
              ),
        ),
      );
    } catch (e) {
      debugPrint('[PhoneAuthPage] send verification failed: $e');
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_verificationErrorMessage(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _verificationErrorMessage(Object error) {
    if (error is ApiException) {
      final body = error.message.trim();
      if (body.isNotEmpty) {
        return 'Failed to send code (${error.statusCode}): $body';
      }
      return 'Failed to send code (${error.statusCode}).';
    }

    final raw = error.toString().toLowerCase();
    if (raw.contains('timeout')) {
      return 'Request timed out. Please try again.';
    }
    if (raw.contains('socket') ||
        raw.contains('network') ||
        raw.contains('connection')) {
      return 'No internet connection. Please check your network.';
    }
    return 'Failed to send verification code.';
  }

  @override
  void initState() {
    super.initState();

    // Initialize with plus sign and focus on code field
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _codeCtrl.text = '+';
      _codeCtrl.selection = TextSelection.fromPosition(TextPosition(offset: 1));
      _codeFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _numberCtrl.dispose();
    _codeFocusNode.dispose();
    _numberFocusNode.dispose();
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
              busy: _isSending,
              onPressed: _canAttemptVerification ? _startVerification : null,
              focusNodes: [_codeFocusNode, _numberFocusNode],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AuthPageHeader(
                    title: widget.isSignInFlow ? 'Log in' : 'Phone number',
                    onBack: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AuthPageSubtitle(
                            child: SizedBox(
                              width: 310,
                              child: Text(
                                widget.isSignInFlow
                                    ? 'Enter your country code and\n'
                                        'phone number to log in.'
                                    : 'Please confirm your country code\n'
                                        'and enter your phone number.',
                                textAlign: TextAlign.center,
                                style: WrytteTypography.authSubtitle,
                              ),
                            ),
                          ),
                          const SizedBox(height: 26),
                          Material(
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
                                  onTap: _pickCountry,
                                  title: Text(
                                    _hasInvalidCountryCode
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
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 16),
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
                                      SizedBox(
                                        width: 70,
                                        child: TextField(
                                          controller: _codeCtrl,
                                          focusNode: _codeFocusNode,
                                          onTapOutside:
                                              (_) =>
                                                  FocusScope.of(
                                                    context,
                                                  ).unfocus(),
                                          cursorColor: WrytteColors.primary,
                                          keyboardType: TextInputType.phone,
                                          style: WrytteTypography.authInput,
                                          decoration: const InputDecoration(
                                            border: InputBorder.none,
                                            enabledBorder: InputBorder.none,
                                            focusedBorder: InputBorder.none,
                                            isDense: true,
                                            contentPadding:
                                                EdgeInsets.symmetric(
                                                  vertical: 8,
                                                ),
                                          ),
                                          onChanged: _detectCountryFromCode,
                                          onTap: _onCodeFieldTap,
                                        ),
                                      ),
                                      if (_showDivider)
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
                                          controller: _numberCtrl,
                                          focusNode: _numberFocusNode,
                                          onTapOutside:
                                              (_) =>
                                                  FocusScope.of(
                                                    context,
                                                  ).unfocus(),
                                          cursorColor: WrytteColors.primary,
                                          keyboardType: TextInputType.phone,
                                          inputFormatters: [
                                            if (_selectedCountry != null)
                                              CountryPhoneNumberInputFormatter(
                                                _selectedCountry!.isoCode,
                                              )
                                            else
                                              FilteringTextInputFormatter
                                                  .digitsOnly,
                                          ],
                                          style: WrytteTypography.authInput,
                                          decoration: InputDecoration(
                                            hintText:
                                                _showDivider
                                                    ? 'Phone number'
                                                    : '',
                                            hintStyle: WrytteTypography
                                                .authInput
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
                                          onChanged: (_) => setState(() {}),
                                          enabled: _showDivider,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (MediaQuery.viewInsetsOf(context).bottom == 0) ...[
                            const SizedBox(height: 24),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 15,
                              ),
                              child: RichText(
                                textAlign: TextAlign.center,
                                text: TextSpan(
                                  style: WrytteTypography.authBody,
                                  children: [
                                    const TextSpan(
                                      text:
                                          'By entering this device’s phone number and tapping “Next,” you agree to ',
                                    ),
                                    TextSpan(
                                      text:
                                          'Wrytte’s Terms and Conditions and Privacy Policy',
                                      style: const TextStyle(
                                        color: WrytteColors.primary,
                                      ),
                                      recognizer:
                                          TapGestureRecognizer()
                                            ..onTap =
                                                () => Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder:
                                                        (_) =>
                                                            const TermsPrivacyPage(),
                                                  ),
                                                ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
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
