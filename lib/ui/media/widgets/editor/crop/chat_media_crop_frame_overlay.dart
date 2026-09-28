import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/media/widgets/editor/crop/chat_media_crop_rotation_dial.dart';

class ChatMediaCropFrameOverlay extends StatefulWidget {
  const ChatMediaCropFrameOverlay({
    super.key,
    required this.editor,
    required this.rebuildStream,
    required this.onRotationChanged,
    required this.onRotationChangeEnd,
  });

  final CropRotateEditorState editor;
  final Stream<void> rebuildStream;

  final ValueChanged<double> onRotationChanged;

  final ValueChanged<double> onRotationChangeEnd;

  @override
  State<ChatMediaCropFrameOverlay> createState() =>
      _ChatMediaCropFrameOverlayState();
}

class _ChatMediaCropFrameOverlayState extends State<ChatMediaCropFrameOverlay>
    with WidgetsBindingObserver {
  final GlobalKey _overlayKey = GlobalKey();

  StreamSubscription<void>? _rebuildSubscription;

  Rect? _cropRect;

  bool _measurementScheduled = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _listenToEditor();
    _scheduleMeasurement();
  }

  @override
  void didUpdateWidget(covariant ChatMediaCropFrameOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.rebuildStream != widget.rebuildStream) {
      _listenToEditor();
    }

    _scheduleMeasurement();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    _scheduleMeasurement();
  }

  @override
  void didChangeMetrics() {
    _scheduleMeasurement();
  }

  void _listenToEditor() {
    unawaited(_rebuildSubscription?.cancel());

    _rebuildSubscription = widget.rebuildStream.listen((_) {
      _scheduleMeasurement();
    });
  }

  void _scheduleMeasurement() {
    if (_measurementScheduled || !mounted) {
      return;
    }

    _measurementScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;

      if (!mounted) {
        return;
      }

      _measureCropRect();
    });
  }

  void _measureCropRect() {
    final cropPainter = widget.editor.cropPainter;

    final cropPainterContext = widget.editor.cropPainterKey.currentContext;

    final overlayContext = _overlayKey.currentContext;

    if (cropPainter == null ||
        cropPainterContext == null ||
        overlayContext == null) {
      _setCropRect(null);
      return;
    }

    final cropBox = cropPainterContext.findRenderObject();

    final overlayBox = overlayContext.findRenderObject();

    if (cropBox is! RenderBox ||
        overlayBox is! RenderBox ||
        !cropBox.attached ||
        !overlayBox.attached ||
        !cropBox.hasSize ||
        !overlayBox.hasSize) {
      _setCropRect(null);
      return;
    }

    final sourceRect = cropPainter.cropRect;

    if (!sourceRect.isFinite || sourceRect.isEmpty) {
      _setCropRect(null);
      return;
    }

    final points =
        <Offset>[
              sourceRect.topLeft,
              sourceRect.topRight,
              sourceRect.bottomRight,
              sourceRect.bottomLeft,
            ]
            .map((point) {
              final global = cropBox.localToGlobal(point);

              return overlayBox.globalToLocal(global);
            })
            .toList(growable: false);

    if (points.any((point) => !point.isFinite)) {
      _setCropRect(null);
      return;
    }

    final left = points
        .map((point) => point.dx)
        .reduce((a, b) => a < b ? a : b);

    final top = points.map((point) => point.dy).reduce((a, b) => a < b ? a : b);

    final right = points
        .map((point) => point.dx)
        .reduce((a, b) => a > b ? a : b);

    final bottom = points
        .map((point) => point.dy)
        .reduce((a, b) => a > b ? a : b);

    final resolved = Rect.fromLTRB(left, top, right, bottom);

    if (!resolved.isFinite || resolved.isEmpty) {
      _setCropRect(null);
      return;
    }

    _setCropRect(resolved);
  }

  void _setCropRect(Rect? next) {
    final current = _cropRect;

    if (current == null && next == null) {
      return;
    }

    if (current != null &&
        next != null &&
        (current.left - next.left).abs() < .25 &&
        (current.top - next.top).abs() < .25 &&
        (current.right - next.right).abs() < .25 &&
        (current.bottom - next.bottom).abs() < .25) {
      return;
    }

    setState(() {
      _cropRect = next;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    unawaited(_rebuildSubscription?.cancel());

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasurement();

    final cropRect = _cropRect;

    return SizedBox.expand(
      key: _overlayKey,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (cropRect != null)
            Positioned(
              // Use the complete crop width so the circular ruler's two
              // endpoints meet the bottom corners of the crop frame.
              left: cropRect.left,
              width: cropRect.width,

              // 1px overlap avoids a visible black seam.
              top: cropRect.bottom - 1,

              height: ChatMediaCropRotationDial.height,

              child: ChatMediaCropRotationDial(
                valueDegrees:
                    widget.editor.activeHistory.tiltRotate *
                    180 /
                    3.141592653589793,

                onChanged: widget.onRotationChanged,

                onChangeEnd: widget.onRotationChangeEnd,
              ),
            ),
        ],
      ),
    );
  }
}
