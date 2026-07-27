import 'package:flutter/material.dart';
import 'package:wrytte/ui/widgets/wrytte_video_player.dart';

/// Sizes a channel video using the decoder's actual dimensions.
class ChannelPostVideo extends StatefulWidget {
  const ChannelPostVideo({
    super.key,
    required this.source,
    this.mediaWidth,
    this.mediaHeight,
  });

  final String source;
  final int? mediaWidth;
  final int? mediaHeight;

  @override
  State<ChannelPostVideo> createState() => _ChannelPostVideoState();
}

class _ChannelPostVideoState extends State<ChannelPostVideo> {
  double? _aspectRatio;

  @override
  void initState() {
    super.initState();
    _setMetadataRatio();
  }

  @override
  void didUpdateWidget(covariant ChannelPostVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.mediaWidth != widget.mediaWidth ||
        oldWidget.mediaHeight != widget.mediaHeight) {
      _aspectRatio = null;
      _setMetadataRatio();
    }
  }

  void _setMetadataRatio() {
    final width = widget.mediaWidth;
    final height = widget.mediaHeight;
    if (width != null && width > 0 && height != null && height > 0) {
      _aspectRatio = width / height;
    }
  }

  void _useDecodedRatio(double ratio) {
    if (!mounted || ratio <= 0 || ratio == _aspectRatio) return;
    setState(() => _aspectRatio = ratio);
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _aspectRatio;
    final isNineBySixteen = ratio != null && (ratio - 9 / 16).abs() <= 0.08;

    return Padding(
      // Only genuine 9:16 videos use the shortened Twitter-style width.
      // Every other ratio keeps the original full post width.
      padding: EdgeInsets.only(right: isNineBySixteen ? 0 : 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          // Genuine 9:16 media ends immediately before the Share action.
          widthFactor: isNineBySixteen ? 0.70 : 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: ratio ?? 16 / 9,
              child: WrytteVideoPlayer(
                source: widget.source,
                autoPlayWhenVisible: true,
                startMuted: true,
                showRemainingTime: true,
                borderRadius: BorderRadius.circular(14),
                onAspectRatioReady: _useDecodedRatio,
                compactOverlays: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
