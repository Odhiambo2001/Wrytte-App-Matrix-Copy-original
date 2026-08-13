import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class KFaceKeyPage extends StatelessWidget {
  const KFaceKeyPage({
    super.key,
    required this.wrytteId,
    required this.keyHash,
  });

  final String wrytteId;
  final String keyHash;

  @override
  Widget build(BuildContext context) {
    final displayId = wrytteId.startsWith('@') ? wrytteId : '@$wrytteId';
    return Scaffold(
      backgroundColor: const Color(0xFF05090A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 62, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  displayId,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 78),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Key:',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: keyHash));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Key copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined, size: 21),
                    label: const Text('Copy'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF989DA5),
                    ),
                  ),
                ],
              ),
              SelectableText(
                keyHash,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed:
                      () => Navigator.of(
                        context,
                      ).popUntil((route) => route.isFirst),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF24282D),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Log out',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
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
