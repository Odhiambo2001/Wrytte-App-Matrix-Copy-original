import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/ui/auth/email_verification_page.dart';

class VirtualNumberPage extends StatefulWidget {
  final String regionCode;

  const VirtualNumberPage({super.key, required this.regionCode});

  @override
  State<VirtualNumberPage> createState() => _VirtualNumberPageState();
}

class _VirtualNumberPageState extends State<VirtualNumberPage> {
  final TextEditingController _emailCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  final VirtualNumberService _service = VirtualNumberService();

  bool _isLoading = false;
  final bool _emailValid = false;
  bool _vpnLoading = true;

  String _virtualNumber = "";

  @override
  void initState() {
    super.initState();
    _fetchVpn();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  ///  STEP 1: Fetch VPN from backend
  Future<void> _fetchVpn() async {
    setState(() {
      _vpnLoading = true;
      _virtualNumber = ""; // clear old number while loading
    });

    try {
      final phone = await _service.getAvailableVpn(
        regionCode: widget.regionCode,
      );

      if (!mounted) return;

      setState(() {
        _virtualNumber = phone;
        _vpnLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() => _vpnLoading = false);

      debugPrint("Virtual number fetch error: $e");

      // Show user-friendly message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to fetch Wrytte ID number"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Send email verification code.
  Future<void> _submit() async {
    if (!_emailValid || _isLoading || _virtualNumber.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      await _service.sendEmailCode(_emailCtrl.text.trim());

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => EmailVerificationPage(
                email: _emailCtrl.text.trim(),
                virtualNumber: _virtualNumber,
              ),
        ),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to send verification email"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
                      ///  BACK
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),

                      const SizedBox(height: 16),

                      /// TITLE
                      const Center(
                        child: Text(
                          "Wrytte ID",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),

                      const SizedBox(height: 30),

                      /// INPUT CARD
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: const Color(0xFF23262C),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10, // <-- REDUCED from 14 to 10
                        ),
                        child:
                            _vpnLoading
                                ? const Center(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(vertical: 4),
                                    child: SizedBox(
                                      height: 14,
                                      width: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                )
                                : Text(
                                  _service.formatWrytteId(
                                    _virtualNumber,
                                    regionCode: widget.regionCode,
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                      ),

                      const Spacer(),

                      /// NEXT BUTTON
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _emailValid && !_isLoading && !_vpnLoading
                                  ? _submit
                                  : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _emailValid
                                    ? const Color(0xFF4DA3FF)
                                    : const Color(0xFF23262C),
                            disabledBackgroundColor: const Color(0xFF23262C),
                            foregroundColor:
                                _emailValid ? Colors.white : Colors.grey,
                            disabledForegroundColor: Colors.grey,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child:
                              _isLoading
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

                      const SizedBox(height: 110),
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
