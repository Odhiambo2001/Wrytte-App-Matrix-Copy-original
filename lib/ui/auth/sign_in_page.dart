import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/ui/auth/login_otp_page.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _isValid = false;
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _goNext() async {
    if (!_isValid || _isLoading) return;

    final input = _inputCtrl.text.trim();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (!mounted) return;

      final phone = _normalizePhone(input);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LoginOtpPage(
            phoneNumber: phone,
            userId: '',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _normalizePhone(String input) {
    var cleaned = input.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _focusNode.dispose();
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
                16,
                24,
                MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      /// Back
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),

                      const SizedBox(height: 10),

                      /// Title
                      const Center(
                        child: Text(
                          "Log In",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),

                      /// Subtitle
                      const Center(
                        child: Text(
                          "Enter your Wrytte ID number or\nPhone number to log in.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 15),
                        ),
                      ),

                      const SizedBox(height: 28),

                      /// Input field
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF23262C),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: TextField(
                          controller: _inputCtrl,
                          focusNode: _focusNode,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                          decoration: const InputDecoration(
                            hintText: "Wrytte ID or Phone number",
                            hintStyle: TextStyle(
                              color: Colors.white54,
                              fontSize: 16,
                            ),
                            border: InputBorder.none,
                            prefixText: "+",
                            prefixStyle: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                            isDense: true,
                          ),
                          onChanged: (value) {
                            setState(() {
                              _isValid = value.trim().isNotEmpty;
                              _errorMessage = null;
                            });
                          },
                        ),
                      ),

                      const SizedBox(height: 12),

                      /// Error message
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                            ),
                          ),
                        ),

                      /// Forgot ID
                      Center(
                        child: GestureDetector(
                          onTap: () {},
                          child: const Text(
                            "Forgot your Wrytte ID?",
                            style: TextStyle(
                              color: Color(0xFF4DA3FF),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),

                      const Spacer(),

                      /// Next button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isValid && !_isLoading ? _goNext : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isValid && !_isLoading
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
                          child: _isLoading
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  "Next",
                                  style: TextStyle(fontSize: 15),
                                ),
                        ),
                      ),

                      const SizedBox(height: 50),
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
