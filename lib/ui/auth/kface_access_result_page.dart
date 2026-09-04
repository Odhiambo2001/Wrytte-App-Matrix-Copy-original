import 'package:flutter/material.dart';

class KFaceAccessResultPage extends StatelessWidget {
  const KFaceAccessResultPage({
    super.key,
    required this.accepted,
    required this.retryPageBuilder,
  });

  final bool accepted;
  final WidgetBuilder retryPageBuilder;

  @override
  Widget build(BuildContext context) {
    final accent = accepted ? const Color(0xFF4285DF) : const Color(0xFFE85D68);
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  accepted ? Icons.check_rounded : Icons.refresh_rounded,
                  color: accent,
                  size: 68,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                accepted ? 'Access accepted' : 'Try again',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                accepted
                    ? 'Your face was verified successfully.'
                    : 'Your face could not be verified.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF92959D),
                  fontSize: 17,
                  height: 1.4,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed:
                      accepted
                          ? () => Navigator.of(
                            context,
                          ).popUntil((route) => route.isFirst)
                          : () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute<void>(builder: retryPageBuilder),
                          ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4285DF),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: Text(
                    accepted ? 'Done' : 'Try again',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
