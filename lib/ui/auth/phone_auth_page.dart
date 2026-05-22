import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/real_number_service.dart';
import 'package:wrytte/ui/auth/country_picker_page.dart';
import 'package:wrytte/ui/screens/terms_privacy_page.dart';
import 'package:wrytte/utils/countries.dart';
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

  /// Full phone number
  String get _fullPhone {
    if (_selectedCountry == null) return '';

    final raw = _numberCtrl.text.trim();
    final normalized = raw.startsWith('0') ? raw.substring(1) : raw;

    return '${_selectedCountry!.dialCode}$normalized';
  }

  /// Validation
  bool get _isValid =>
      _selectedCountry != null && _numberCtrl.text.trim().length >= 8;

  /// Pick country
  Future<void> _pickCountry() async {
    final result = await Navigator.of(context).push<Country>(
      MaterialPageRoute(builder: (_) => const CountryPickerPage()),
    );

    if (result != null) {
      setState(() {
        _selectedCountry = result;
        _codeCtrl.text = '+${result.dialCode}'; // Keep the plus sign
        _showDivider = true;
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

    // Extract just the dial code for detection
    final codeWithoutPlus = value.substring(1);

    for (final country in countries) {
      if (country.dialCode == codeWithoutPlus) {
        setState(() {
          _selectedCountry = country;
          _showDivider = true;
        });

        // Auto-fill complete: move focus to number field
        if (!_isAutoFilling && codeWithoutPlus.isNotEmpty) {
          _isAutoFilling = true;
          Future.delayed(const Duration(milliseconds: 100), () {
            _numberFocusNode.requestFocus();
            _isAutoFilling = false;
          });
        }
        break;
      }
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
    if (!_isValid || _isSending || _sendCodeFuture != null) return;

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

  Future<void> _sendVerificationCode() async {
    try {
      await _realNumberService.sendSmsCode(_fullPhone);

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => OtpVerificationPage(
                phoneNumber: _fullPhone,
                isSignInFlow: widget.isSignInFlow,
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
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                24,
                0,
                24,
                MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      /// Back Button
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),

                      const SizedBox(height: 10),

                      /// Title
                      const Center(
                        child: Text(
                          "Phone number",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),

                      Center(
                        child: Text(
                          "Please confirm your country code\nand enter your phone number.",
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 15,
                            height: 1.1,
                          ),
                        ),
                      ),

                      const SizedBox(height: 30),

                      /// Country + Phone Container
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF23262C),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          mainAxisSize:
                              MainAxisSize
                                  .min, // <-- ADD THIS to minimize height
                          children: [
                            /// Country Selector
                            ListTile(
                              onTap: _pickCountry,
                              title: Text(
                                _selectedCountry == null
                                    ? "Country"
                                    : "${_selectedCountry!.flag} ${_selectedCountry!.name}",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize:
                                      15, // <-- OPTIONAL: reduced from 16 to 15
                                ),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right,
                                color: Colors.white,
                                size:
                                    22, // <-- OPTIONAL: slightly reduced icon size
                              ),
                              dense:
                                  true, // <-- ADD THIS for more compact ListTile
                              visualDensity:
                                  VisualDensity
                                      .compact, // <-- ADD THIS for tighter spacing
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical:
                                    8, // <-- ADD THIS to control vertical padding
                              ),
                            ),

                            /// Divider with padding
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16),
                              child: Divider(color: Colors.white12, height: 1),
                            ),

                            /// Phone Row
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8, // <-- REDUCED from 12 to 8
                              ),
                              child: Row(
                                children: [
                                  /// Country Code Input
                                  SizedBox(
                                    width: 70,
                                    child: TextField(
                                      controller: _codeCtrl,
                                      focusNode: _codeFocusNode,
                                      keyboardType: TextInputType.phone,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize:
                                            15, // <-- OPTIONAL: reduced from 16 to 15
                                      ),
                                      decoration: const InputDecoration(
                                        hintText: "",
                                        border: InputBorder.none,
                                        isDense:
                                            true, // <-- ADD THIS for compact input
                                        contentPadding: EdgeInsets.symmetric(
                                          vertical: 8,
                                        ), // <-- ADD THIS to control height
                                      ),
                                      onChanged: _detectCountryFromCode,
                                      onTap: _onCodeFieldTap,
                                    ),
                                  ),

                                  /// Blue Divider (only shown after code auto-fill)
                                  if (_showDivider)
                                    Container(
                                      height: 22, // <-- REDUCED from 26 to 22
                                      width: 1,
                                      color: const Color(0xFF4DA3FF),
                                      margin: const EdgeInsets.symmetric(
                                        horizontal:
                                            8, // <-- REDUCED from 10 to 8
                                      ),
                                    ),

                                  /// Phone Number Input
                                  Expanded(
                                    child: TextField(
                                      controller: _numberCtrl,
                                      focusNode: _numberFocusNode,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize:
                                            15, // <-- OPTIONAL: reduced from 16 to 15
                                      ),
                                      decoration: InputDecoration(
                                        hintText:
                                            _showDivider ? "Phone number" : "",
                                        hintStyle: const TextStyle(
                                          color: Colors.white38,
                                          fontSize:
                                              15, // <-- OPTIONAL: reduced from 16 to 15
                                        ),
                                        border: InputBorder.none,
                                        isDense:
                                            true, // <-- ADD THIS for compact input
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 8,
                                            ), // <-- ADD THIS to control height
                                      ),
                                      onChanged: (_) => setState(() {}),
                                      enabled:
                                          _showDivider, // Disable until code is entered
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 25),

                      /// Terms
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 15),
                        child: RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: const TextStyle(color: Colors.white),
                            children: [
                              const TextSpan(
                                text:
                                    "By entering this device’s phone number and tapping “Next,” you agree to ",
                              ),
                              TextSpan(
                                text:
                                    "Wrytte’s Terms and Conditions and Privacy Policy",
                                style: const TextStyle(
                                  color: Color(0xFF4DA3FF),
                                ),
                                recognizer:
                                    TapGestureRecognizer()
                                      ..onTap = () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder:
                                                (_) => const TermsPrivacyPage(),
                                          ),
                                        );
                                      },
                              ),
                            ],
                          ),
                        ),
                      ),

                      const Spacer(),

                      /// Next Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _isValid && !_isSending
                                  ? _startVerification
                                  : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isValid && !_isSending
                                    ? const Color(0xFF4DA3FF)
                                    : const Color(0xFF23262C),
                            disabledBackgroundColor: const Color(0xFF23262C),
                            foregroundColor:
                                _isValid ? Colors.white : Colors.grey,
                            disabledForegroundColor: Colors.grey,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child:
                              _isSending
                                  ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                  : const Text(
                                    "Next",
                                    style: TextStyle(fontSize: 16),
                                  ),
                        ),
                      ),

                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
