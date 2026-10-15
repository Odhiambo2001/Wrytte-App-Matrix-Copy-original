import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wrytte/services/attachment_local_store.dart';
import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_bubble_surface.dart';
import 'package:wrytte/ui/chat/widgets/message_metadata.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/views/full_screen_image_view.dart';

class ImageMessageBubble extends StatefulWidget {
  const ImageMessageBubble({
    super.key,
    required this.message,
    this.showTail = true,
    this.actionConfig,
  });

  final ChatMessagePresentation message;
  final bool showTail;
  final MessageActionConfig? actionConfig;

  @override
  State<ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends State<ImageMessageBubble> {
  final GlobalKey _imageSurfaceKey = GlobalKey(
    debugLabel: 'chat-image-surface',
  );

  // ===========================================================================
  // Geometry
  // ===========================================================================

  static const double _bubbleRadius = 18.0;
  static const double _outlineWidth = 1.2;
  static const double _minimumImageWidth = 148.0;
  static const double _maximumBubbleWidth = 420.0;
  static const double _captionWidthFactor = 0.80;
  static const double _landscapeScreenInset = 64.0;
  static const double _portraitWidthFactor = 0.70;
  static const double _maximumMediaHeight = 420.0;
  static const double _maximumMediaHeightFactor = 0.44;
  static const double _minimumAspectRatio = 0.45;
  static const double _maximumAspectRatio = 2.60;
  static const double _captionHorizontalPadding = 12.0;
  static const double _captionMetadataGap = 8.0;
  static const double _captionMinimumMetadataGap = 6.0;
  static const double _overlayBadgeInset = 5.0;
  static const double _overlayBadgeBottomInset = 4.0;
  static const double _outgoingOverlayShift = 4.0;

  static const TextStyle _captionStyle = TextStyle(
    fontFamily: WrytteTypography.primaryFontFamily,
    color: WrytteColors.textPrimary,
    fontSize: 16.0,
    fontWeight: FontWeight.w400,
    height: 1.28,
  );

  // ===========================================================================
  // Image state
  // ===========================================================================

  double _aspectRatio = 4 / 3;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  String? _resolvedLocalPath;
  bool _resolvingLocal = false;

  // ===========================================================================
  // Message values
  // ===========================================================================

  String get _source => widget.message.assetPath?.trim() ?? '';

  String get _paintSource => _resolvedLocalPath ?? _source;

  String? get _caption {
    final value = widget.message.text?.trim() ?? '';
    if (value.isEmpty) return null;
    final normalized = value.toLowerCase();
    if (const <String>{
      'photo',
      'image',
      'attachment',
      'photo message',
    }.contains(normalized)) {
      return null;
    }
    if (RegExp(
      r'\.(png|jpe?g|gif|webp|bmp|heic|heif)$',
      caseSensitive: false,
    ).hasMatch(value)) {
      return null;
    }
    return value;
  }

  bool get _hasCaption => _caption != null;
  bool get _isMine => widget.message.isMine;

  
  // Captions belong to the media surface. They must not become a separate
  // outgoing-message blue footer; the source bubble keeps this section dark
  // for both incoming and outgoing media.
  Color get _captionBackgroundColor => WrytteColors.surfaceRaised;

  // The media frame follows the dark media surface. The sender's blue
  // message color must not create a blue outline around portrait media.
  Color get _outlineColor => WrytteColors.surfaceRaised;

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_resolveLocalFile());
    _resolveImageDimensions();
  }

  @override
  void didUpdateWidget(covariant ImageMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.assetPath != widget.message.assetPath) {
      _aspectRatio = 4 / 3;
      _resolvedLocalPath = null;
      _detachImageListener();
      unawaited(_resolveLocalFile());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _resolveImageDimensions();
      });
    }
  }

  @override
  void dispose() {
    _detachImageListener();
    super.dispose();
  }

  // ===========================================================================
  // Local file resolution (fixes Matrix 401)
  // ===========================================================================

  String _fileNameFromSource(String source) {
    final fromText = widget.message.text?.trim() ?? '';
    if (fromText.isNotEmpty &&
        RegExp(r'\.(png|jpe?g|gif|webp|heic|heif)$', caseSensitive: false)
            .hasMatch(fromText)) {
      return fromText;
    }
    try {
      final name = Uri.parse(source).pathSegments.last;
      if (name.isNotEmpty) return name;
    } catch (_) {}
    return 'image.jpg';
  }

  Future<void> _resolveLocalFile() async {
    final source = _source;
    if (source.isEmpty || _resolvingLocal) return;

    // Already a local path
    if (!source.startsWith('http://') &&
        !source.startsWith('https://') &&
        !source.startsWith('mxc://')) {
      final path =
          source.startsWith('file:') ? Uri.parse(source).toFilePath() : source;
      if (File(path).existsSync()) {
        if (mounted) {
          setState(() => _resolvedLocalPath = path);
          _resolveImageDimensions();
        }
        return;
      }
    }

    _resolvingLocal = true;
    try {
      final fileName = _fileNameFromSource(source);

      final existing = await AttachmentLocalStore.instance.existingComplete(
        source: source,
        fileName: fileName,
      );
      if (existing != null) {
        if (mounted) {
          setState(() => _resolvedLocalPath = existing.path);
          _resolveImageDimensions();
        }
        return;
      }

      final copy = await AttachmentLocalStore.instance.ensureComplete(
        source: source,
        fileName: fileName,
      );
      if (mounted) {
        setState(() => _resolvedLocalPath = copy.file.path);
        _resolveImageDimensions();
      }
    } catch (_) {
      // Keep placeholder on failure
    } finally {
      _resolvingLocal = false;
    }
  }

  // ===========================================================================
  // Image dimensions
  // ===========================================================================

  void _resolveImageDimensions() {
    final provider = _imageProviderFor(_paintSource);
    if (provider == null) return;

    _detachImageListener();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((
      ImageInfo info,
      bool synchronousCall,
    ) {
      final double width = info.image.width.toDouble();
      final double height = info.image.height.toDouble();
      if (width <= 0 || height <= 0) return;

      final double nextRatio = width / height;
      if (!mounted) return;
      if ((_aspectRatio - nextRatio).abs() < 0.001) return;

      setState(() => _aspectRatio = nextRatio);
    }, onError: (Object error, StackTrace? stackTrace) {});

    _imageStream = stream;
    _imageListener = listener;
    stream.addListener(listener);
  }

  void _detachImageListener() {
    final stream = _imageStream;
    final listener = _imageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _imageStream = null;
    _imageListener = null;
  }

  // ===========================================================================
  // Image provider — never use unauthenticated NetworkImage for Matrix media
  // ===========================================================================

  ImageProvider? _imageProviderFor(String source) {
    final effective = _resolvedLocalPath ?? source;
    if (effective.isEmpty) return null;

    if (effective.startsWith('assets/')) {
      return AssetImage(effective);
    }

    if (!effective.startsWith('http://') &&
        !effective.startsWith('https://') &&
        !effective.startsWith('mxc://')) {
      final path = effective.startsWith('file:')
          ? Uri.parse(effective).toFilePath()
          : effective;
      return FileImage(File(path));
    }

    // Remote Matrix URL not yet resolved → do not use NetworkImage (401)
    return null;
  }

  Future<void> _openFullScreenImage() async {
    final provider = _imageProviderFor(_paintSource);
    if (provider == null) return;

    final config = widget.actionConfig;
    final actionHandler = config?.onActionSelected;
    final origin = ExpandingSurfaceOrigin.fromKey(
      _imageSurfaceKey,
      borderRadius: BorderRadius.circular(_bubbleRadius),
    );

    final result = await showWrytteImageViewer(
      context,
      image: provider,
      origin: origin,
      imageAspectRatio: _aspectRatio,
      title: widget.message.isMine
          ? 'You'
          : (widget.message.senderName?.trim().isNotEmpty == true
                ? widget.message.senderName!.trim()
                : 'Wrytte Team'),
      subtitle: widget.message.timeLabel,
      caption: widget.message.text,
      onShare: actionHandler == null
          ? null
          : () => unawaited(
              Future<void>.sync(
                () => actionHandler(const MessageAction.forward()),
              ),
            ),
      onDownload: actionHandler == null
          ? null
          : () => unawaited(
              Future<void>.sync(
                () => actionHandler(const MessageAction.save()),
              ),
            ),
      onEdit: actionHandler == null || !widget.message.isMine
          ? null
          : () => unawaited(
              Future<void>.sync(
                () => actionHandler(const MessageAction.editMedia()),
              ),
            ),
      onReply: actionHandler == null
          ? null
          : () {
              Navigator.of(context, rootNavigator: true).maybePop();
              unawaited(
                Future<void>.sync(
                  () => actionHandler(const MessageAction.reply()),
                ),
              );
            },
      onShowInChat: () => Navigator.of(context, rootNavigator: true).maybePop(),
      allowDelete: actionHandler != null,
    );

    if (!mounted || result != FullScreenImageResult.deleteRequested) return;
    await actionHandler?.call(const MessageAction.delete());
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final config = widget.actionConfig;
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size screenSize = MediaQuery.sizeOf(context);
        final double tailExtent =
            widget.showTail ? MessageBubbleSurface.tailExtent : 0.0;
        final double availableBodyWidth = constraints.hasBoundedWidth
            ? math.max(0.0, constraints.maxWidth - tailExtent).toDouble()
            : screenSize.width;

        final double safeAspect = _aspectRatio
            .clamp(_minimumAspectRatio, _maximumAspectRatio)
            .toDouble();
        final double maxHeight = math
            .min(
              screenSize.height * _maximumMediaHeightFactor,
              _maximumMediaHeight,
            )
            .toDouble();

        final double preferredImageMaxWidth = safeAspect >= 1.0
            ? math
                .min(
                  screenSize.width - _landscapeScreenInset,
                  _maximumBubbleWidth,
                )
                .toDouble()
            : math
                .min(screenSize.width * _portraitWidthFactor, 340.0)
                .toDouble();

        double imageWidth =
            math.min(availableBodyWidth, preferredImageMaxWidth).toDouble();
        double imageHeight = imageWidth / safeAspect;

        if (imageHeight > maxHeight) {
          imageHeight = maxHeight;
          imageWidth = imageHeight * safeAspect;
        }

        if (imageWidth < _minimumImageWidth) {
          imageWidth =
              math.min(_minimumImageWidth, availableBodyWidth).toDouble();
          imageHeight =
              math.min(maxHeight, imageWidth / safeAspect).toDouble();
        }

        // Keep the bubble exactly as wide as the real image. Expanding it
        // beyond the image causes blurred side-fill panels.
        final double bubbleBodyWidth = imageWidth;
        final double bubbleSurfaceWidth = bubbleBodyWidth + tailExtent;

        final Widget bubble = SizedBox(
          width: bubbleSurfaceWidth,
          child: _MediaBubbleFrame(
            isMine: _isMine,
            showTail: widget.showTail,
            radius: _bubbleRadius,
            outlineColor: _outlineColor,
            outlineWidth: _outlineWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(color: _captionBackgroundColor),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildImageArea(
                    bodyWidth: bubbleBodyWidth,
                    actualImageWidth: imageWidth,
                    imageHeight: imageHeight,
                  ),
                  if (_hasCaption)
                    _ImageTextCaption(
                      text: _caption!,
                      message: widget.message,
                      isMine: _isMine,
                      showTail: widget.showTail,
                      tailExtent: tailExtent,
                    ),
                ],
              ),
            ),
          ),
        );

        final EdgeInsetsGeometry groupedInset = widget.showTail
            ? EdgeInsets.zero
            : EdgeInsetsDirectional.only(
                start: _isMine ? 0.0 : MessageBubbleSurface.tailExtent,
                end: _isMine ? MessageBubbleSurface.tailExtent : 0.0,
              );

        final Widget content = Padding(
          padding: groupedInset,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.0),
            child: bubble,
          ),
        );

        return Align(
          alignment: _isMine
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          child: config == null || !config.hasContent
              ? content
              : MessageActionTarget(
                  config: config,
                  child: MessageSwipeActionTarget(
                    config: config,
                    child: content,
                  ),
                ),
        );
      },
    );
  }

  // ===========================================================================
  // Image area
  // ===========================================================================

  Widget _buildImageArea({
    required double bodyWidth,
    required double actualImageWidth,
    required double imageHeight,
  }) {
    final bool needsBlurFill = (bodyWidth - actualImageWidth).abs() > 0.5;

    return GestureDetector(
      key: _imageSurfaceKey,
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_openFullScreenImage()),
      child: SizedBox(
        width: bodyWidth,
        height: imageHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (needsBlurFill) ...[
              _buildBlurredBackgroundImage(),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.08),
                ),
              ),
            ] else
              _buildBaseImage(),
            if (needsBlurFill)
              Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: actualImageWidth,
                  height: imageHeight,
                  child: _buildForegroundImage(),
                ),
              ),
            if (!_hasCaption)
              PositionedDirectional(
                end: _isMine && widget.showTail
                    ? MessageBubbleSurface.tailExtent + _overlayBadgeInset
                    : _overlayBadgeInset,
                bottom: _overlayBadgeBottomInset,
                child: Transform.translate(
                  offset: Offset(_isMine ? _outgoingOverlayShift : 0, 0),
                  child: _MediaOverlayBadge(
                    compensateStatusOffset: widget.message.isMine,
                    child: MessageMetadata(
                      message: widget.message,
                      onMedia: true,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // Image renderers
  // ===========================================================================

  Widget _buildBaseImage() {
    if (_source.isEmpty && _resolvedLocalPath == null) return _errorImage();
    return _buildImageWithFit(BoxFit.cover);
  }

  Widget _buildForegroundImage() {
    if (_source.isEmpty && _resolvedLocalPath == null) return _errorImage();
    return _buildImageWithFit(BoxFit.cover);
  }

  Widget _buildBlurredBackgroundImage() {
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: 14.0,
        sigmaY: 14.0,
        tileMode: TileMode.clamp,
      ),
      child: Transform.scale(
        scale: 1.08,
        child: _buildImageWithFit(BoxFit.cover),
      ),
    );
  }

  Widget _buildImageWithFit(BoxFit fit) {
    final source = _paintSource;
    if (source.isEmpty) return _errorImage();

    if (source.startsWith('assets/')) {
      return Image.asset(
        source,
        fit: fit,
        alignment: Alignment.center,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stackTrace) => _errorImage(),
      );
    }

    final uri = Uri.tryParse(source);
    final isRemote = uri != null &&
        (uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'mxc');

    // Still resolving remote Matrix media → loading placeholder (never NetworkImage)
    if (isRemote ||
        (_resolvedLocalPath == null &&
            (_source.startsWith('http') || _source.startsWith('mxc')))) {
      return const ColoredBox(
        color: Color(0xFF1B1E23),
        child: Center(
          child: SizedBox.square(
            dimension: 24.0,
            child: CircularProgressIndicator(
              strokeWidth: 2.0,
              color: WrytteColors.textSecondary,
            ),
          ),
        ),
      );
    }

    final filePath =
        uri?.scheme == 'file' ? uri!.toFilePath() : source;

    return Image.file(
      File(filePath),
      fit: fit,
      alignment: Alignment.center,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => _errorImage(),
    );
  }

  Widget _errorImage() {
    return const ColoredBox(
      color: Color(0xFF1B1E23),
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: WrytteColors.textMuted,
          size: 38.0,
        ),
      ),
    );
  }

  // ===========================================================================
  // Measurement
  // ===========================================================================

  double _measureCaptionBubbleWidth(
    BuildContext context,
    String caption,
    double metadataWidth,
    double maxWidth,
  ) {
    final maximumContentWidth = math.max(
      0.0,
      maxWidth - (_captionHorizontalPadding * 2),
    );
    final layout = _MediaTextLayoutResolver.resolve(
      context: context,
      text: caption,
      style: _captionStyle,
      maximumWidth: maximumContentWidth,
      metadataWidth: metadataWidth,
      preferredMetadataGap: _captionMetadataGap,
      minimumMetadataGap: _captionMinimumMetadataGap,
    );
    return (layout.width + (_captionHorizontalPadding * 2))
        .clamp(0.0, maxWidth)
        .toDouble();
  }

  double _measureMediaMetadataWidth(BuildContext context) {
    return MessageMetadata.measure(context, widget.message).width;
  }
}

// =============================================================================
// Caption section
// =============================================================================

class _ImageTextCaption extends StatelessWidget {
  const _ImageTextCaption({
    required this.text,
    required this.message,
    required this.isMine,
    required this.showTail,
    required this.tailExtent,
  });

  final String text;
  final ChatMessagePresentation message;
  final bool isMine;
  final bool showTail;
  final double tailExtent;

  static const double _horizontalPadding = 12;
  static const double _topPadding = 7;
  static const double _bottomPadding = 6;
  static const double _preferredMetadataGap = 8;
  static const double _minimumMetadataGap = 6;

  @override
  Widget build(BuildContext context) {
    final startPadding =
        _horizontalPadding + (!isMine && showTail ? tailExtent : 0);
    final endPadding =
        _horizontalPadding + (isMine && showTail ? tailExtent : 0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maximumContentWidth = math.max(
          0.0,
          constraints.maxWidth - startPadding - endPadding,
        );
        final metadataWidth = MessageMetadata.measure(context, message).width;
        final layout = _MediaTextLayoutResolver.resolve(
          context: context,
          text: text,
          style: _ImageMessageBubbleState._captionStyle,
          maximumWidth: maximumContentWidth,
          metadataWidth: metadataWidth,
          preferredMetadataGap: _preferredMetadataGap,
          minimumMetadataGap: _minimumMetadataGap,
        );
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            startPadding,
            _topPadding,
            endPadding,
            _bottomPadding,
          ),
          child: _MediaMeasuredTextBody(
            text: text,
            message: message,
            style: _ImageMessageBubbleState._captionStyle,
            layout: layout,
          ),
        );
      },
    );
  }
}

class _MediaMeasuredTextBody extends StatelessWidget {
  const _MediaMeasuredTextBody({
    required this.text,
    required this.message,
    required this.style,
    required this.layout,
  });

  final String text;
  final ChatMessagePresentation message;
  final TextStyle style;
  final _MediaTextLayout layout;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final bodySpan = TextSpan(text: text, style: style);

    if (!layout.metadataIsInline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            bodySpan,
            textDirection: direction,
            textScaler: scaler,
            locale: locale,
            textAlign: TextAlign.start,
          ),
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.centerRight,
            child: _rightAlignedMetadata(),
          ),
        ],
      );
    }

    if (layout.bodyIsSingleLine) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text.rich(
              bodySpan,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              textDirection: direction,
              textScaler: scaler,
              locale: locale,
              textAlign: TextAlign.start,
            ),
          ),
          SizedBox(width: layout.metadataGap),
          _rightAlignedMetadata(),
        ],
      );
    }

    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Text.rich(
          TextSpan(
            style: style,
            children: [
              TextSpan(text: text),
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: SizedBox(width: layout.metadataReservation, height: 17),
              ),
            ],
          ),
          textDirection: direction,
          textScaler: scaler,
          locale: locale,
          textAlign: TextAlign.start,
        ),
        Positioned(right: 0, bottom: 0, child: _rightAlignedMetadata()),
      ],
    );
  }

  Widget _rightAlignedMetadata() {
    return Transform.translate(
      offset: Offset(message.isMine ? 5 : 0, 0),
      child: MessageMetadata(message: message),
    );
  }
}

class _MediaTextLayout {
  const _MediaTextLayout({
    required this.width,
    required this.metadataIsInline,
    required this.metadataReservation,
    required this.metadataGap,
    required this.bodyIsSingleLine,
  });

  final double width;
  final bool metadataIsInline;
  final double metadataReservation;
  final double metadataGap;
  final bool bodyIsSingleLine;
}

class _MediaTextLayoutResolver {
  static const double _tolerance = .05;

  static _MediaTextLayout resolve({
    required BuildContext context,
    required String text,
    required TextStyle style,
    required double maximumWidth,
    required double metadataWidth,
    required double preferredMetadataGap,
    required double minimumMetadataGap,
  }) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);

    if (maximumWidth <= 0) {
      return const _MediaTextLayout(
        width: 0,
        metadataIsInline: false,
        metadataReservation: 0,
        metadataGap: 0,
        bodyIsSingleLine: false,
      );
    }

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout(maxWidth: maximumWidth);

    final lines = painter.computeLineMetrics();
    final widestLine = lines.fold<double>(
      0,
      (widest, line) => math.max(widest, line.width),
    );
    final finalLine = lines.isEmpty ? 0.0 : lines.last.width;
    final lineCount = lines.length;
    final hasForcedTrailingLine = text.endsWith('\\\n');

    var inline = false;
    var gap = preferredMetadataGap;
    if (!hasForcedTrailingLine && lines.isNotEmpty) {
      inline = finalLine + gap + metadataWidth <= maximumWidth + _tolerance;
      if (!inline &&
          finalLine + minimumMetadataGap + metadataWidth <=
              maximumWidth + _tolerance) {
        gap = minimumMetadataGap;
        inline = true;
      }
    }

    final inlineWidthSlack = lineCount == 1 ? 2.0 : 0.0;
    var desiredWidth = inline
        ? math.max(
            widestLine,
            finalLine + gap + metadataWidth + inlineWidthSlack,
          )
        : math.max(widestLine, metadataWidth);
    desiredWidth = desiredWidth.clamp(0.0, maximumWidth).toDouble();

    painter.layout(maxWidth: desiredWidth);
    final narrowedLines = painter.computeLineMetrics();
    final narrowedFinal =
        narrowedLines.isEmpty ? 0.0 : narrowedLines.last.width;
    final preservesLayout = narrowedLines.length == lineCount;
    final inlineStillFits = !inline ||
        narrowedFinal + gap + metadataWidth <= desiredWidth + _tolerance;

    if (!preservesLayout || !inlineStillFits) {
      desiredWidth = maximumWidth;
    }

    painter.dispose();

    return _MediaTextLayout(
      width: desiredWidth,
      metadataIsInline: inline,
      metadataReservation: inline ? gap + metadataWidth : 0,
      metadataGap: inline ? gap : 0,
      bodyIsSingleLine: lineCount == 1,
    );
  }
}

// =============================================================================
// Media metadata badge
// =============================================================================

class _MediaOverlayBadge extends StatelessWidget {
  const _MediaOverlayBadge({
    required this.child,
    this.compensateStatusOffset = false,
  });

  final Widget child;
  final bool compensateStatusOffset;

  static const double _height = 22;
  static const double _horizontalPadding = 6;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.44),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
          child: Center(
            child: Transform.translate(
              offset: Offset(0, compensateStatusOffset ? -1 : 0),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Media bubble frame
// =============================================================================

class _MediaBubbleFrame extends StatelessWidget {
  const _MediaBubbleFrame({
    required this.isMine,
    required this.showTail,
    required this.radius,
    required this.outlineColor,
    required this.outlineWidth,
    required this.child,
  });

  final bool isMine;
  final bool showTail;
  final double radius;
  final Color outlineColor;
  final double outlineWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _MediaBubbleOutlinePainter(
        isMine: isMine,
        showTail: showTail,
        radius: radius,
        color: outlineColor,
        strokeWidth: outlineWidth,
      ),
      child: ClipPath(
        clipBehavior: Clip.antiAliasWithSaveLayer,
        clipper: _MediaBubbleClipper(
          isMine: isMine,
          showTail: showTail,
          radius: radius,
        ),
        child: child,
      ),
    );
  }
}

class _MediaBubbleClipper extends CustomClipper<Path> {
  const _MediaBubbleClipper({
    required this.isMine,
    required this.showTail,
    required this.radius,
  });

  final bool isMine;
  final bool showTail;
  final double radius;

  @override
  Path getClip(Size size) {
    return _MediaBubblePath.create(
      size: size,
      tailOnRight: isMine,
      showTail: showTail,
      strokeInset: 0.0,
      radius: radius,
    );
  }

  @override
  bool shouldReclip(covariant _MediaBubbleClipper oldClipper) {
    return oldClipper.isMine != isMine ||
        oldClipper.showTail != showTail ||
        oldClipper.radius != radius;
  }
}

class _MediaBubbleOutlinePainter extends CustomPainter {
  const _MediaBubbleOutlinePainter({
    required this.isMine,
    required this.showTail,
    required this.radius,
    required this.color,
    required this.strokeWidth,
  });

  final bool isMine;
  final bool showTail;
  final double radius;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strokeWidth <= 0) return;

    final Path path = _MediaBubblePath.create(
      size: size,
      tailOnRight: isMine,
      showTail: showTail,
      strokeInset: strokeWidth / 2,
      radius: radius,
    );

    canvas.drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _MediaBubbleOutlinePainter oldDelegate) {
    return oldDelegate.isMine != isMine ||
        oldDelegate.showTail != showTail ||
        oldDelegate.radius != radius ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _MediaBubblePath {
  static const double _templateDiameter = 33.0;
  static const double _bottomEllipseLeftInset = 10.5;
  static const double _bottomEllipseWidth = 30.0;
  static const double _bottomEllipseHeight = 17.0;
  static const double _innerEllipseWidth = 22.0;
  static const double _innerEllipseHeight = 20.0;
  static const double _bridgeWidth = 18.0;
  static const double _bridgeTopInset = 17.0;
  static const double _bridgeBottomInset = 8.0;

  static Path create({
    required Size size,
    required bool tailOnRight,
    required bool showTail,
    required double strokeInset,
    required double radius,
  }) {
    if (size.isEmpty) return Path();

    if (!showTail) {
      return _roundedBody(
        Rect.fromLTRB(
          strokeInset,
          strokeInset,
          size.width - strokeInset,
          size.height - strokeInset,
        ),
        radius,
      );
    }

    final Path outgoingPath = _createRightTailBubble(
      size: size,
      strokeInset: strokeInset,
      radius: radius,
    );
    if (tailOnRight) return outgoingPath;

    return outgoingPath.transform(
      Float64List.fromList(<double>[
        -1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        size.width, 0, 0, 1,
      ]),
    );
  }

  static Path _createRightTailBubble({
    required Size size,
    required double strokeInset,
    required double radius,
  }) {
    final double availableWidth = math.max(0.0, size.width - strokeInset * 2);
    final double availableHeight = math.max(0.0, size.height - strokeInset * 2);
    if (availableWidth <= 0 || availableHeight <= 0) return Path();

    final double tailScale = math.min(1.0, availableHeight / _templateDiameter);
    final double reservedTail = math.min(
      MessageBubbleSurface.tailExtent,
      math.max(0.0, availableWidth - 1.0),
    );
    final Rect bodyRect = Rect.fromLTRB(
      strokeInset,
      strokeInset,
      size.width - strokeInset - reservedTail,
      size.height - strokeInset,
    );
    if (bodyRect.width <= 0 || bodyRect.height <= 0) return Path();

    final Path bodyPath = _roundedBody(bodyRect, radius);
    final double bodyRight = bodyRect.right;
    final double bottom = bodyRect.bottom;

    final Rect bottomEllipse = Rect.fromLTWH(
      bodyRight - (_bottomEllipseLeftInset * tailScale),
      bottom - (_bottomEllipseHeight * tailScale),
      _bottomEllipseWidth * tailScale,
      _bottomEllipseHeight * tailScale,
    );
    final Path lowerLobe = Path()
      ..moveTo(bottomEllipse.left, bottomEllipse.center.dy)
      ..quadraticBezierTo(
        bottomEllipse.left,
        bottomEllipse.bottom,
        bottomEllipse.center.dx,
        bottomEllipse.bottom,
      )
      ..quadraticBezierTo(
        bottomEllipse.right,
        bottomEllipse.bottom,
        bottomEllipse.right,
        bottomEllipse.center.dy,
      )
      ..close();

    final Path bridge = Path()
      ..addRect(
        Rect.fromLTRB(
          bodyRight - (_bridgeWidth * tailScale),
          bottom - (_bridgeTopInset * tailScale),
          bodyRight,
          bottom - (_bridgeBottomInset * tailScale),
        ),
      );

    Path combined = Path.combine(PathOperation.union, bodyPath, lowerLobe);
    combined = Path.combine(PathOperation.union, combined, bridge);

    final Path innerCutout = Path()
      ..addOval(
        Rect.fromLTWH(
          bodyRight,
          bottom - (19.0 * tailScale),
          _innerEllipseWidth * tailScale,
          _innerEllipseHeight * tailScale,
        ),
      );

    return Path.combine(PathOperation.difference, combined, innerCutout);
  }

  static Path _roundedBody(Rect rect, double requestedRadius) {
    if (rect.width <= 0 || rect.height <= 0) return Path();
    final Radius resolvedRadius = Radius.circular(
      math.min(requestedRadius, math.min(rect.width / 2, rect.height / 2)),
    );
    return Path()..addRRect(RRect.fromRectAndRadius(rect, resolvedRadius));
  }
}
