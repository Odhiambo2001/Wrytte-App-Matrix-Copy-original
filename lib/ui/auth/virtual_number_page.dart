import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/ui/auth/kface_intro_page.dart';

class VirtualNumberPage extends StatefulWidget {
  final String regionCode;

  const VirtualNumberPage({super.key, required this.regionCode});

  @override
  State<VirtualNumberPage> createState() => _VirtualNumberPageState();
}

class _VirtualNumberPageState extends State<VirtualNumberPage> {
  final VirtualNumberService _service = VirtualNumberService();

  bool _vpnLoading = true;
  bool _fetchFailed = false;

  String _virtualNumber = "";

  @override
  void initState() {
    super.initState();
    _fetchVpn();
  }

  ///  STEP 1: Fetch VPN from backend
  Future<void> _fetchVpn({bool refresh = false}) async {
    setState(() {
      _vpnLoading = true;
      _fetchFailed = false;
      _virtualNumber = ""; // clear old number while loading
    });

    try {
      final candidate =
          refresh
              ? await _service.refreshAvailableVpn(
                regionCode: widget.regionCode,
              )
              : await _service.getAvailableVpn(regionCode: widget.regionCode);

      if (!mounted) return;

      setState(() {
        _virtualNumber = candidate.number;
        _fetchFailed = false;
        _vpnLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _vpnLoading = false;
        _fetchFailed = true;
      });

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

  Future<void> _refreshVpn() async {
    if (_vpnLoading) return;
    await _fetchVpn(refresh: true);
  }

  Future<void> _openKFace() async {
    if (_vpnLoading || _virtualNumber.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => KFaceIntroPage(wrytteId: _virtualNumber),
      ),
    );
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
                                : _fetchFailed || _virtualNumber.isEmpty
                                ? Center(
                                  child: TextButton(
                                    onPressed: _fetchVpn,
                                    child: const Text(
                                      'Retry',
                                      style: TextStyle(
                                        color: Color(0xFF4DA3FF),
                                      ),
                                    ),
                                  ),
                                )
                                : Row(
                                  children: [
                                    Expanded(
                                      child: Text(
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
                                    IconButton(
                                      tooltip: 'Refresh Wrytte ID',
                                      onPressed: _refreshVpn,
                                      icon: const Icon(
                                        Icons.refresh,
                                        color: Color(0xFF4DA3FF),
                                      ),
                                    ),
                                  ],
                                ),
                      ),

                      const Spacer(),

                      /// NEXT BUTTON
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              !_vpnLoading && _virtualNumber.isNotEmpty
                                  ? _openKFace
                                  : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4DA3FF),
                            disabledBackgroundColor: const Color(0xFF23262C),
                            foregroundColor: Colors.white,
                            disabledForegroundColor: Colors.grey,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text(
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
