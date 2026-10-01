import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/core/theme.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/ui/auth/widgets/auth_intro_body.dart';
import 'package:wrytte/ui/auth/widgets/wrytte_id_checkmark.dart';

class VirtualNumberPage extends StatefulWidget {
  final String? regionCode;
  final Future<String>? regionCodeFuture;

  const VirtualNumberPage({
    super.key,
    this.regionCode,
    this.regionCodeFuture,
  }) : assert(regionCode != null || regionCodeFuture != null);

  @override
  State<VirtualNumberPage> createState() => _VirtualNumberPageState();
}

class _VirtualNumberPageState extends State<VirtualNumberPage> {
  final VirtualNumberService _service = VirtualNumberService();
  final TapGestureRecognizer _generateRecognizer = TapGestureRecognizer();

  bool _vpnLoading = true;
  bool _fetchFailed = false;
  String _virtualNumber = '';
  String? _resolvedRegionCode;

  @override
  void initState() {
    super.initState();
    _resolveRegionThenFetch();
  }

  Future<void> _resolveRegionThenFetch() async {
    try {
      _resolvedRegionCode =
          widget.regionCode ?? await widget.regionCodeFuture!;
      await _fetchVpn();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _vpnLoading = false;
        _fetchFailed = true;
      });
      debugPrint('Virtual number region detection error: $error');
    }
  }

  @override
  void dispose() {
    _generateRecognizer.dispose();
    super.dispose();
  }

  Future<void> _fetchVpn() async {
    setState(() {
      _vpnLoading = true;
      _fetchFailed = false;
      _virtualNumber = '';
    });

    try {
      final regionCode = _resolvedRegionCode;
      if (regionCode == null) throw StateError('Region is not ready');
      // Reuse the cached number when the user taps "Click here" again.
      final candidate = await _service.getAvailableVpn(
        regionCode: regionCode,
      );

      if (!mounted) return;
      setState(() {
        _virtualNumber = candidate.number;
        _fetchFailed = false;
        _vpnLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _vpnLoading = false;
        _fetchFailed = true;
      });
      debugPrint('Virtual number fetch error: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to fetch Wrytte ID number'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _openKFace() async {
    if (_vpnLoading || _virtualNumber.isEmpty) return;
    await Navigator.pushNamed(
      context,
      '/auth/kface',
      arguments: <String, Object?>{
        'wrytteId': _virtualNumber,
        'isEnrollment': true,
        'userId': null,
        'attachToExistingUser': false,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    _generateRecognizer.onTap =
        _vpnLoading ? null : _fetchVpn;

    return Scaffold(
      backgroundColor: WrytteTheme.background,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: !_vpnLoading && _virtualNumber.isNotEmpty
                      ? _openKFace
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4DA3FF),
                    disabledBackgroundColor: WrytteColors.surfaceRaised,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: const Color(0xFF9A9DA4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: const StadiumBorder(),
                    textStyle: WrytteTypography.authButtonLabel,
                  ),
                  child: const Text('Next', textAlign: TextAlign.center),
                ),
              ),
            ),
          ),
        ),
      ),
      body: AuthIntroBody(
        spacious: true,
        title: 'Wrytte ID',
        onBack: () => Navigator.pop(context),
        subtitleGap: 4,
        subtitle: SizedBox(
          width: 280,
          child: Text.rich(
            TextSpan(
              style: WrytteTypography.authSubtitle,
              children: [
                const TextSpan(text: 'To create another Wrytte ID '),
                TextSpan(
                  text: 'Click here',
                  style: const TextStyle(color: WrytteColors.primary),
                  recognizer: _generateRecognizer,
                ),
              ],
            ),
            textAlign: TextAlign.center,
          ),
        ),
        visual: Container(
          key: const ValueKey('wrytte-id-number'),
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: WrytteColors.surfaceRaised, width: 1.5),
          ),
          child: _vpnLoading
              ? const Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Row(
                  textDirection: TextDirection.ltr,
                  children: [
                    Expanded(
                      child: Text(
                        _virtualNumber.isEmpty
                            ? 'Unable to create ID. Try again.'
                            : _service.formatWrytteId(
                                _virtualNumber,
                                regionCode: _resolvedRegionCode ?? 'US',
                              ),
                        textAlign: _virtualNumber.isEmpty
                            ? TextAlign.center
                            : TextAlign.left,
                        textDirection: TextDirection.ltr,
                        style: WrytteTypography.authInput,
                      ),
                    ),
                    if (_virtualNumber.isNotEmpty) const SizedBox(width: 8),
                    if (_virtualNumber.isNotEmpty)
                      const SizedBox(
                        width: 30,
                        child: Center(child: WrytteIdCheckmark()),
                      ),
                  ],
                ),
        ),
        details: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'What is the Wrytte ID ?',
              textAlign: TextAlign.center,
              style: WrytteTypography.authSectionTitleLarge,
            ),
            SizedBox(height: 16),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 280),
                child: Text(
                  'Wrytte ID is a secure identifier for\n'
                  'private calls, messaging, and\n'
                  'communication.',
                  textAlign: TextAlign.center,
                  style: WrytteTypography.authBody,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
