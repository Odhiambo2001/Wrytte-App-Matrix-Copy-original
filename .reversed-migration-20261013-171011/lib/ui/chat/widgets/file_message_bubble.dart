import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/chat/widgets/message_bubble_surface.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_metadata.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class FileMessageBubble extends StatefulWidget {
  const FileMessageBubble({
    super.key,
    required this.message,
    required this.showTail,
    this.actionConfig,
  });

  final ChatMessagePresentation message;
  final bool showTail;
  final MessageActionConfig? actionConfig;

  @override
  State<FileMessageBubble> createState() =>
      _FileMessageBubbleState();
}

class _FileMessageBubbleState extends State<FileMessageBubble> {
  Widget _withMessageActions(Widget bubble) {
    final config = widget.actionConfig;

    if (config == null || !config.hasContent) {
      return bubble;
    }

    return MessageActionTarget(
                  config: config,
                  child: MessageSwipeActionTarget(
                    config: config,
                    child: bubble,
                  ),
                );
  }

  // ===========================================================================
  // Geometry
  // ===========================================================================

  static const double _maxBubbleWidth = 280.0;

  // Canonical outgoing metadata guide from TextMessageBubble.
  static const double _outgoingMetadataEndInset = 7.0;
  static const double _metadataContainerEndInset = 12.0;
  static const double _outgoingMetadataShift =
      _metadataContainerEndInset - _outgoingMetadataEndInset;

  static const double _sharedAttachmentCircleSize = 44.0;

  static const double _previewLeftInset = 3.0;

  /// Slightly tighter than the old 11px gap.
  static const double _previewTextGap = 8.0;

  static const double _fileLeadingWidth =
      _previewLeftInset +
      _sharedAttachmentCircleSize +
      _previewTextGap;

  /// Long names are allowed to use this much text width before truncation.
  ///
  /// This prevents a huge original filename from forcing the whole bubble
  /// to its maximum width.
  static const double _compactPreferredNameWidth = 178.0;

  /// Small paint reserve only.
  ///
  /// Previously this was much larger and made filenames truncate too early.
  static const double _fileNamePaintSafetyWidth = 4.0;

  static const int _mp3UntruncatedCharacterLimit = 18;

  // ===========================================================================
  // UI-only state
  // ===========================================================================

  bool _audioPlaying = false;

  bool _downloading = false;
  bool _uiDownloaded = false;

  Timer? _fakeDownloadTimer;

  // ===========================================================================
  // File identity
  // ===========================================================================

  String get _fileName {
    return _cleanFileNameForDisplay(
      widget.message.fileName ?? 'File',
    );
  }

  String get _extension {
    final index = _fileName.lastIndexOf('.');

    if (index < 0 ||
        index == _fileName.length - 1) {
      return '';
    }

    return _fileName
        .substring(index + 1)
        .trim()
        .toUpperCase();
  }

  String get _fileStem {
    final index = _fileName.lastIndexOf('.');

    if (index <= 0) {
      return _fileName;
    }

    return _fileName
        .substring(0, index)
        .trim();
  }

  bool get _isPdf =>
      _extension == 'PDF';

  bool get _isAudio =>
      _isAudioExtension(_extension);

  bool get _isImage =>
      _isImageExtension(_extension);

  // ===========================================================================
  // Source
  // ===========================================================================

  String get _source {
    return widget.message.assetPath?.trim() ?? '';
  }

  bool get _isRemoteFile {
    final source = _source.toLowerCase();

    return source.startsWith('http://') ||
        source.startsWith('https://');
  }

  bool get _hasLocalSource {
    return _source.isNotEmpty &&
        !_isRemoteFile;
  }

  // ===========================================================================
  // Caption
  // ===========================================================================

  bool get _hasCaption {
    final value =
        widget.message.text?.trim() ?? '';

    if (value.isEmpty) {
      return false;
    }

    return value != _fileName;
  }

  // ===========================================================================
  // Transfer state
  // ===========================================================================

  bool get _isSending {
    return widget.message.isMine &&
        widget.message.deliveryState ==
            ChatDeliveryState.pending;
  }

  bool get _showDownloadingVisual {
    return _downloading ||
        _isSending;
  }

  bool get _showDownload {
    return !widget.message.isMine &&
        _isRemoteFile &&
        !_uiDownloaded &&
        !_downloading;
  }

  // ===========================================================================
  // File metadata
  // ===========================================================================

  List<String> get _detailParts {
    final value =
        widget.message.fileDetails?.trim() ?? '';

    if (value.isEmpty) {
      return const [];
    }

    return value
        .split('·')
        .map(
          (part) => part.trim(),
        )
        .where(
          (part) => part.isNotEmpty,
        )
        .toList(
          growable: false,
        );
  }

  // ===========================================================================
  // Audio metadata
  // ===========================================================================

  String? get _audioArtist {
    if (!_isAudio) {
      return null;
    }

    final parts = _detailParts;

    if (parts.isEmpty) {
      return null;
    }

    final first = parts.first;

    if (_looksLikeDuration(first) ||
        _looksLikeFileSize(first) ||
        _looksLikeExtension(first)) {
      return null;
    }

    return first;
  }

  bool get _hasAudioArtist =>
      _audioArtist != null;

  String get _audioFileNameForDisplay {
    final originalName = _fileName;

    // Old MP3 style:
    //
    // Meeting theme.mp3
    //
    // displays as:
    //
    // Meeting theme
    if (_extension == 'MP3') {
      return _fileStem.isEmpty
          ? 'Audio file'
          : _fileStem;
    }

    return originalName;
  }

  String? get _audioDurationLabel {
    final suppliedSeconds =
        widget.message.audioDurationSeconds ?? 0;

    if (suppliedSeconds > 0) {
      final minutes =
          suppliedSeconds ~/ 60;

      final seconds =
          suppliedSeconds
              .remainder(60)
              .toString()
              .padLeft(
                2,
                '0',
              );

      return '$minutes:$seconds';
    }

    for (final part in _detailParts) {
      if (_looksLikeDuration(part)) {
        return part;
      }
    }

    return null;
  }

  // ===========================================================================
  // File size
  // ===========================================================================

  String? get _fileSizeLabel {
    final details =
        widget.message.fileDetails?.trim() ?? '';

    if (details.isEmpty) {
      return null;
    }

    final match = RegExp(
      r'\b\d+(?:\.\d+)?\s*(?:B|KB|MB|GB|TB)\b',
      caseSensitive: false,
    ).firstMatch(
      details,
    );

    return match?.group(0);
  }

  String? get _fileDetailsText {
    final total =
        _fileSizeLabel;

    if (_showDownloadingVisual) {
      return total == null
          ? '0 KB'
          : '0 KB / $total';
    }

    return total;
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  @override
  void didUpdateWidget(
    covariant FileMessageBubble oldWidget,
  ) {
    super.didUpdateWidget(
      oldWidget,
    );

    if (oldWidget.message.id !=
            widget.message.id ||
        oldWidget.message.assetPath !=
            widget.message.assetPath ||
        oldWidget.message.fileName !=
            widget.message.fileName) {
      _fakeDownloadTimer?.cancel();

      _downloading = false;
      _uiDownloaded = false;
      _audioPlaying = false;
    }
  }

  @override
  void dispose() {
    _fakeDownloadTimer?.cancel();

    super.dispose();
  }

  // ===========================================================================
  // Interaction
  // ===========================================================================

  void _handleTap() {
    if (_showDownloadingVisual) {
      if (_downloading) {
        _cancelFakeDownload();
      }

      return;
    }

    if (_showDownload) {
      _startFakeDownload();
      return;
    }

    if (_isAudio) {
      setState(() {
        _audioPlaying =
            !_audioPlaying;
      });
    }
  }

  void _startFakeDownload() {
    _fakeDownloadTimer?.cancel();

    setState(() {
      _downloading = true;
    });

    _fakeDownloadTimer =
        Timer(
      const Duration(
        milliseconds: 1500,
      ),
      () {
        if (!mounted) {
          return;
        }

        setState(() {
          _downloading = false;
          _uiDownloaded = true;
        });
      },
    );
  }

  void _cancelFakeDownload() {
    _fakeDownloadTimer?.cancel();

    setState(() {
      _downloading = false;
      _uiDownloaded = false;
    });
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    if (_isPdf) {
      return _buildPdfBubble(
        context,
      );
    }

    return _buildCompactFileBubble(
      context,
    );
  }

  // ===========================================================================
  // Compact file bubble
  // ===========================================================================

  Widget _buildCompactFileBubble(
    BuildContext context,
  ) {
    final message =
        widget.message;

    // =========================================================================
    // Old Wrytte color relationship
    // =========================================================================

    final iconBackground =
        message.isMine
        ? WrytteColors.textPrimary
        : WrytteColors.primary;

    final iconForeground =
        message.isMine
        ? WrytteColors.primary
        : WrytteColors.textPrimary;

    // =========================================================================
    // Typography
    // =========================================================================

    const fileNameStyle =
        TextStyle(
      color:
          WrytteColors.textPrimary,
      fontSize:
          17.5,
      fontWeight:
          FontWeight.w500,
      height:
          1,
    );

    const audioArtistStyle =
        TextStyle(
      color:
          Color(0xBFC6C6C6),
      fontSize:
          14.5,
      fontWeight:
          FontWeight.w400,
      height:
          1,
    );

    const audioMetadataStyle =
        TextStyle(
      color:
          Color(0xBFC6C6C6),
      fontSize:
          11,
      fontWeight:
          FontWeight.w400,
      height:
          1,
    );

    final effectiveFileNameStyle =
        DefaultTextStyle.of(
      context,
    ).style.merge(
      fileNameStyle,
    );

    // =========================================================================
    // Display title
    // =========================================================================

    final fileNameForDisplay =
        _isAudio
        ? _audioFileNameForDisplay
        : _fileName;

    final titleForWidth =
        _extension == 'MP3'
        ? _mp3TitleUsedForWidth(
            fileNameForDisplay,
          )
        : fileNameForDisplay;

    // =========================================================================
    // Measurements
    // =========================================================================

    final metadataSize =
        MessageMetadata.measure(
      context,
      message,
    );

    final textScaler =
        MediaQuery.textScalerOf(
      context,
    );

    final textDirection =
        Directionality.of(
      context,
    );

    double measuredTextWidth(
      String? text,
      TextStyle style,
    ) {
      if (text == null ||
          text.isEmpty) {
        return 0.0;
      }

      final painter =
          TextPainter(
        text:
            TextSpan(
          text:
              text,
          style:
              style,
        ),
        maxLines:
            1,
        textDirection:
            textDirection,
        textScaler:
            textScaler,
      )..layout();

      final width =
          painter.width;

      painter.dispose();

      return width;
    }

    final double nameWidth =
        measuredTextWidth(
      titleForWidth,
      effectiveFileNameStyle,
    );

    final double artistWidth =
        measuredTextWidth(
      _audioArtist,
      audioArtistStyle,
    );

    final duration =
        _isAudio
        ? _audioDurationLabel
        : null;

    final size =
        _fileDetailsText;

    var fileMetadataWidth =
        _isAudio
        ? 15.0
        : 0.0;

    if (duration != null) {
      fileMetadataWidth +=
          3.0 +
          measuredTextWidth(
            duration,
            audioMetadataStyle,
          );
    }

    if (duration != null &&
        size != null) {
      fileMetadataWidth +=
          7.0 +
          4.0 +
          7.0;
    }

    if (size != null) {
      fileMetadataWidth +=
          measuredTextWidth(
            size,
            audioMetadataStyle,
          );
    }

    const double metadataToTimestampGap =
        12.0;

    final double lowerRowWidth =
        fileMetadataWidth +
        metadataToTimestampGap +
        metadataSize.width;

    const double fileNameRightInset =
        0.0;

    final double safeNameWidth =
        nameWidth +
        fileNameRightInset +
        _fileNamePaintSafetyWidth;

    // =========================================================================
    // IMPORTANT WIDTH FIX
    //
    // Audio keeps the original adaptive sizing.
    //
    // Normal files have a preferred filename budget. Long filenames truncate
    // instead of forcing every bubble toward max width.
    // =========================================================================

    final double effectiveNameWidth =
        _isAudio
        ? safeNameWidth
        : math.min(
            safeNameWidth,
            _compactPreferredNameWidth,
          );

    final double requiredTextWidth =
        math.max(
      effectiveNameWidth,
      math.max(
        artistWidth,
        lowerRowWidth,
      ),
    );

    // =========================================================================
    // Minimum width
    // =========================================================================

    final double baseMinimumFileWidth =
        _isAudio
        ? 190.0
        : _hasCaption
            ? 200.0
            : 150.0;

    final viewportWidth =
        MediaQuery.sizeOf(
      context,
    ).width;

    final double responsiveMaximum =
        math.max(
      0.0,
      math.min(
        _maxBubbleWidth,
        viewportWidth - 44.0,
      ),
    );

    final double minimumWidth =
        math.min(
      baseMinimumFileWidth,
      responsiveMaximum,
    );

    // =========================================================================
    // Actual content width
    //
    // Short files:
    //
    //   index.js
    //
    // no longer get the same width as:
    //
    //   extremely-long-project-production-file-name...
    // =========================================================================

    final double fileBubbleWidth =
        math
            .max(
              minimumWidth,
              _fileLeadingWidth +
                  requiredTextWidth,
            )
            .clamp(
              minimumWidth,
              responsiveMaximum,
            )
            .toDouble();

    // =========================================================================
    // Heights
    // =========================================================================

    final double rowHeight =
        _isAudio
        ? (_hasAudioArtist
            ? 66.0
            : 56.0)
        : 52.0;

    // =========================================================================
    // Padding
    // =========================================================================

    final EdgeInsets bubblePadding =
        _hasCaption
        ? const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          )
        : _hasAudioArtist
            ? const EdgeInsets.fromLTRB(
                10,
                8,
                12,
                8,
              )
            : const EdgeInsets.fromLTRB(
                10,
                16,
                12,
                16,
              );

    final double bubbleRadius =
        _hasCaption
        ? 18.0
        : 20.0;

    // =========================================================================
    // UI
    // =========================================================================

    return Align(
      alignment:
          message.isMine
          ? AlignmentDirectional
              .centerEnd
          : AlignmentDirectional
              .centerStart,
      child:
          _withMessageActions(
            MessageBubbleSurface(
        isMine:
            message.isMine,
        showTail:
            widget.showTail,
        color:
            message.isMine
            ? WrytteColors.primary
            : WrytteColors.surfaceRaised,
        radius:
            bubbleRadius,
        child:
            GestureDetector(
          behavior:
              HitTestBehavior.opaque,
          onTap:
              _handleTap,
          child:
              Padding(
            padding:
                bubblePadding,
            child:
                SizedBox(
              key:
                  const ValueKey(
                'file-bubble-content',
              ),
              width:
                  fileBubbleWidth,
              child:
                  Column(
                mainAxisSize:
                    MainAxisSize.min,
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height:
                        rowHeight,
                    child:
                        Row(
                      children: [
                        // =====================================================
                        // File preview circle
                        // =====================================================

                        Padding(
                          padding:
                              const EdgeInsets.only(
                            left:
                                _previewLeftInset,
                          ),
                          child:
                              Container(
                            key:
                                const ValueKey(
                              'file-preview-circle',
                            ),
                            width:
                                _sharedAttachmentCircleSize,
                            height:
                                _sharedAttachmentCircleSize,
                            alignment:
                                Alignment.center,
                            decoration:
                                BoxDecoration(
                              color:
                                  iconBackground,
                              shape:
                                  BoxShape.circle,
                            ),
                            clipBehavior:
                                Clip.antiAlias,
                            child:
                                AnimatedSwitcher(
                              duration:
                                  const Duration(
                                milliseconds:
                                    220,
                              ),
                              switchInCurve:
                                  Curves.easeOutCubic,
                              switchOutCurve:
                                  Curves.easeInCubic,
                              transitionBuilder:
                                  (
                                child,
                                animation,
                              ) {
                                final scale =
                                    Tween<double>(
                                  begin:
                                      0.88,
                                  end:
                                      1,
                                ).animate(
                                  animation,
                                );

                                return FadeTransition(
                                  opacity:
                                      animation,
                                  child:
                                      ScaleTransition(
                                    scale:
                                        scale,
                                    child:
                                        child,
                                  ),
                                );
                              },
                              child:
                                  KeyedSubtree(
                                key:
                                    ValueKey(
                                  _showDownloadingVisual
                                      ? 'downloading'
                                      : _showDownload
                                          ? 'download'
                                          : _isAudio
                                              ? 'audio:$_audioPlaying'
                                              : 'file',
                                ),
                                child:
                                    _buildFileActionControl(
                                  iconBackground:
                                      iconBackground,
                                  iconForeground:
                                      iconForeground,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // =====================================================
                        // Tightened gap
                        // =====================================================

                        const SizedBox(
                          width:
                              _previewTextGap,
                        ),

                        // =====================================================
                        // File information
                        // =====================================================

                        Expanded(
                          child:
                              LayoutBuilder(
                            builder:
                                (
                              context,
                              constraints,
                            ) {
                              return Stack(
                                clipBehavior:
                                    Clip.none,
                                children: [
                                  // -------------------------------------------
                                  // Filename
                                  // -------------------------------------------

                                  Positioned(
                                    left:
                                        0,
                                    top:
                                        3,
                                    right:
                                        0,
                                    child:
                                        _ExtensionSafeFileName(
                                      key:
                                          const ValueKey(
                                        'file-name',
                                      ),
                                      fileName:
                                          fileNameForDisplay,
                                      maxCharacters:
                                          _extension ==
                                                  'MP3'
                                              ? _mp3UntruncatedCharacterLimit
                                              : null,
                                      style:
                                          effectiveFileNameStyle,
                                      maxWidth:
                                          constraints.maxWidth,
                                    ),
                                  ),

                                  // -------------------------------------------
                                  // Audio artist
                                  // -------------------------------------------

                                  if (_hasAudioArtist)
                                    Positioned(
                                      left:
                                          0,
                                      top:
                                          29,
                                      right:
                                          0,
                                      child:
                                          Text(
                                        _audioArtist!,
                                        maxLines:
                                            1,
                                        softWrap:
                                            false,
                                        overflow:
                                            TextOverflow
                                                .ellipsis,
                                        style:
                                            audioArtistStyle,
                                      ),
                                    ),

                                  // -------------------------------------------
                                  // Metadata / filesize
                                  // -------------------------------------------

                                  Positioned(
                                    left:
                                        0,
                                    right:
                                        null,
                                    top:
                                        _isAudio &&
                                                !_hasAudioArtist
                                            ? 29
                                            : !_isAudio
                                                ? 28
                                                : null,
                                    bottom:
                                        _hasAudioArtist
                                        ? -2
                                        : null,
                                    child:
                                        DefaultTextStyle(
                                      style:
                                          audioMetadataStyle,
                                      child:
                                          _isAudio
                                          ? Align(
                                              alignment:
                                                  Alignment.centerLeft,
                                              widthFactor:
                                                  1,
                                              child:
                                                  _buildAudioMetadataLine(),
                                            )
                                          : AnimatedSwitcher(
                                              duration:
                                                  const Duration(
                                                milliseconds:
                                                    180,
                                              ),
                                              switchInCurve:
                                                  Curves.easeOut,
                                              switchOutCurve:
                                                  Curves.easeIn,
                                              child:
                                                  _fileDetailsText ==
                                                          null
                                                      ? const SizedBox(
                                                          key:
                                                              ValueKey(
                                                            'file-size-empty',
                                                          ),
                                                          height:
                                                              13,
                                                        )
                                                      : Text(
                                                          _fileDetailsText!,
                                                          key:
                                                              const ValueKey(
                                                            'file-size',
                                                          ),
                                                        ),
                                            ),
                                    ),
                                  ),

                                  // -------------------------------------------
                                  // Time / ticks
                                  // -------------------------------------------

                                  Positioned(
                                    right:
                                        0,
                                    bottom:
                                        _hasAudioArtist
                                        ? 0
                                        : -8,
                                    child:
                                        _buildAlignedMessageMetadata(),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  // =========================================================
                  // Caption
                  // =========================================================

                  if (_hasCaption)
                    Padding(
                      padding:
                          const EdgeInsets.only(
                        top:
                            7,
                        left:
                            2,
                        right:
                            2,
                      ),
                      child:
                          Text(
                        widget.message.text!
                            .trim(),
                        style:
                            const TextStyle(
                          color:
                              WrytteColors.textPrimary,
                          fontSize:
                              17,
                          fontWeight:
                              FontWeight.w400,
                          height:
                              1.25,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
          ),
    );
  }

  Widget _buildAlignedMessageMetadata() {
    return Transform.translate(
      offset: Offset(
        widget.message.isMine ? _outgoingMetadataShift : 0,
        0,
      ),
      child: MessageMetadata(
        message: widget.message,
      ),
    );
  }

  // ===========================================================================
  // Circle action control
  // ===========================================================================

  Widget _buildFileActionControl({
    required Color iconBackground,
    required Color iconForeground,
  }) {
    // =========================================================================
    // Downloading / sending
    // =========================================================================

    if (_showDownloadingVisual) {
      return SizedBox.expand(
        child:
            Stack(
          fit:
              StackFit.expand,
          alignment:
              Alignment.center,
          children: [
            Center(
              child:
                  RepaintBoundary(
                child:
                    SizedBox.square(
                  dimension:
                      34,
                  child:
                      CircularProgressIndicator(
                    strokeWidth:
                        2.2,
                    strokeCap:
                        StrokeCap.round,
                    color:
                        iconForeground,
                    backgroundColor:
                        iconForeground.withValues(
                      alpha:
                          0.20,
                    ),
                  ),
                ),
              ),
            ),

            Center(
              child:
                  Icon(
                Icons.close_rounded,
                color:
                    iconForeground,
                size:
                    23,
              ),
            ),
          ],
        ),
      );
    }

    // =========================================================================
    // Incoming remote file
    // =========================================================================

    if (_showDownload) {
      return Icon(
        Icons.file_download_outlined,
        color:
            iconForeground,
        size:
            26,
      );
    }

    // =========================================================================
    // Audio file
    // =========================================================================

    if (_isAudio) {
      return SizedBox.expand(
        child:
            Stack(
          fit:
              StackFit.expand,
          children: [
            DecoratedBox(
              decoration:
                  BoxDecoration(
                color:
                    iconBackground,
                shape:
                    BoxShape.circle,
              ),
            ),

            Center(
              child:
                  AnimatedSwitcher(
                duration:
                    const Duration(
                  milliseconds:
                      170,
                ),
                switchInCurve:
                    Curves.easeOutBack,
                switchOutCurve:
                    Curves.easeInCubic,
                child:
                    Icon(
                  _audioPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  key:
                      ValueKey<bool>(
                    _audioPlaying,
                  ),
                  color:
                      iconForeground,
                  size:
                      29,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // =========================================================================
    // Local image file
    // =========================================================================

    if (_isImage &&
        _hasLocalSource) {
      final file =
          _localFile;

      if (file != null) {
        return ClipOval(
          child:
              SizedBox.expand(
            child:
                Image.file(
              file,
              fit:
                  BoxFit.cover,
              alignment:
                  Alignment.center,
              gaplessPlayback:
                  true,
              errorBuilder:
                  (
                context,
                error,
                stackTrace,
              ) {
                return _buildFileTypeIcon(
                  iconBackground:
                      iconBackground,
                  iconForeground:
                      iconForeground,
                );
              },
            ),
          ),
        );
      }
    }

    // =========================================================================
    // Generic file
    // =========================================================================

    return _buildFileTypeIcon(
      iconBackground:
          iconBackground,
      iconForeground:
          iconForeground,
    );
  }

  // ===========================================================================
  // File document icon
  // ===========================================================================

  Widget _buildFileTypeIcon({
    required Color iconBackground,
    required Color iconForeground,
  }) {
    final String label =
        _extension.isEmpty
        ? ''
        : _extension.length > 4
            ? _extension.substring(
                0,
                4,
              )
            : _extension;

    final bool hasWideLabel =
        label.length >= 4;

    /*
     * Important:
     *
     * The OUTER circle remains 44.
     *
     * Only the paper/document icon itself grows slightly for wide extension
     * labels such as:
     *
     * DOCX
     * XLSX
     * JSON
     * DART
     */
    final double documentIconSize =
        hasWideLabel
        ? 36.0
        : 34.0;

    final double labelWidth =
        hasWideLabel
        ? 21.0
        : 19.0;

    return Stack(
      alignment:
          Alignment.center,
      children: [
        Icon(
          Icons.insert_drive_file_rounded,
          color:
              iconForeground,
          size:
              documentIconSize,
        ),

        if (label.isNotEmpty)
          Padding(
            padding:
                const EdgeInsets.only(
              top:
                  8,
            ),
            child:
                SizedBox(
              width:
                  labelWidth,
              height:
                  9,
              child:
                  FittedBox(
                fit:
                    BoxFit.scaleDown,
                alignment:
                    Alignment.center,
                child:
                    Text(
                  label,
                  maxLines:
                      1,
                  softWrap:
                      false,
                  style:
                      TextStyle(
                    color:
                        iconBackground,
                    fontSize:
                        7.5,
                    fontWeight:
                        FontWeight.w800,
                    height:
                        1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ===========================================================================
  // Audio metadata
  // ===========================================================================

  Widget _buildAudioMetadataLine() {
    final duration =
        _audioDurationLabel;

    final size =
        _fileDetailsText;

    return AnimatedSwitcher(
      duration:
          const Duration(
        milliseconds:
            180,
      ),
      switchInCurve:
          Curves.easeOut,
      switchOutCurve:
          Curves.easeIn,
      child:
          Row(
        key:
            ValueKey<String>(
          'audio-meta:$duration:$size',
        ),
        mainAxisSize:
            MainAxisSize.min,
        crossAxisAlignment:
            CrossAxisAlignment.center,
        children: [
          WrytteSvgIcon(
            asset:
                'assets/svg/Audio icon.svg',
            size:
                15,
            color:
                const Color(
              0xBFC6C6C6,
            ),
          ),

          if (duration != null) ...[
            const SizedBox(
              width:
                  3,
            ),
            Text(
              duration,
            ),
          ],

          if (duration != null &&
              size != null) ...[
            const SizedBox(
              width:
                  7,
            ),
            Container(
              width:
                  4,
              height:
                  4,
              decoration:
                  const BoxDecoration(
                color:
                    Color(
                  0x99C6C6C6,
                ),
                shape:
                    BoxShape.circle,
              ),
            ),
            const SizedBox(
              width:
                  7,
            ),
          ],

          if (size != null)
            Text(
              size,
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PDF
  // ===========================================================================
Widget _buildPdfBubble(
  BuildContext context,
) {
  final message =
      widget.message;

  const pdfRed =
      Color(0xFFB3261E);

  const pdfNameStyle =
      TextStyle(
    color: WrytteColors.textPrimary,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.02,
  );

  const pdfDetailsStyle =
      TextStyle(
    color: Color(0xA6F2F2F2),
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1,
  );

  final bubbleBackground =
      message.isMine
          ? WrytteColors.primary
          : WrytteColors.surfaceRaised;

  final viewportWidth =
      MediaQuery.sizeOf(context).width;

  final double width =
      math.max(
    0.0,
    math.min(
      _maxBubbleWidth,
      viewportWidth - 44.0,
    ),
  );

  final downloaded =
      !_showDownload &&
      !_showDownloadingVisual;

  Widget buildFileSize() {
    final details =
        _fileDetailsText;

    return AnimatedSwitcher(
      duration:
          const Duration(
        milliseconds: 180,
      ),
      switchInCurve:
          Curves.easeOut,
      switchOutCurve:
          Curves.easeIn,
      child:
          details == null ||
                  details.isEmpty
              ? const SizedBox(
                  key: ValueKey(
                    'pdf-size-empty',
                  ),
                )
              : Text(
                  details,
                  key: ValueKey<String>(
                    'pdf-size:$details',
                  ),
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                  style:
                      pdfDetailsStyle,
                ),
    );
  }

  return Align(
    alignment:
        message.isMine
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
    child:
        _withMessageActions(
      MessageBubbleSurface(
        isMine: message.isMine,
        showTail: widget.showTail,
        color: bubbleBackground,
        radius: 18,
        child: GestureDetector(
          behavior:
              HitTestBehavior.opaque,
          onTap: _handleTap,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.stretch,
              children: [
                // =========================================================
                // PDF preview
                // =========================================================

                Container(
                  height: 144,
                  padding:
                      const EdgeInsets.all(4),
                  decoration:
                      BoxDecoration(
                    color: bubbleBackground,
                    borderRadius:
                        BorderRadius.circular(
                      18,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(
                      14,
                    ),
                    child:
                        _PdfPreviewLoadingSurface(
                      loading:
                          _showDownloadingVisual,
                      child:
                          _PdfDocumentIcon(
                        loading:
                            _showDownloadingVisual,
                        downloaded:
                            downloaded,
                        color: pdfRed,
                      ),
                    ),
                  ),
                ),

                // =========================================================
                // PDF info
                // =========================================================

                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(
                    12,
                    10,
                    12,
                    8,
                  ),
                  child: SizedBox(
                    height: 58,
                    child: Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        _PdfDocumentIcon(
                          loading:
                              _showDownloadingVisual,
                          downloaded:
                              downloaded,
                          color: pdfRed,
                        ),

                        const SizedBox(
                          width: 12,
                        ),

                        Expanded(
                          child: LayoutBuilder(
                            builder: (
                              context,
                              constraints,
                            ) {
                              final textPainter =
                                  TextPainter(
                                text: TextSpan(
                                  text: _fileName,
                                  style:
                                      pdfNameStyle,
                                ),
                                textDirection:
                                    Directionality.of(
                                  context,
                                ),
                                textScaler:
                                    MediaQuery.textScalerOf(
                                  context,
                                ),
                                maxLines: 1,
                                ellipsis: '…',
                              )..layout(
                                      maxWidth:
                                          constraints.maxWidth,
                                    );

                              final hasTwoLineName =
                                  textPainter.didExceedMaxLines;

                              textPainter.dispose();

                              if (hasTwoLineName) {
                                // ===========================================
                                // 2-line filename:
                                // put size and metadata on the same row
                                // ===========================================

                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _fileName,
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow.ellipsis,
                                      style:
                                          pdfNameStyle,
                                    ),

                                    const Spacer(),

                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Expanded(
                                          child: buildFileSize(),
                                        ),

                                        const SizedBox(
                                          width: 10,
                                        ),

                                        _buildAlignedMessageMetadata(),
                                      ],
                                    ),
                                  ],
                                );
                              }

                              // =============================================
                              // 1-line filename:
                              // keep size closer to filename,
                              // metadata stays bottom-right
                              // =============================================

                              return Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _fileName,
                                    maxLines: 1,
                                    overflow:
                                        TextOverflow.ellipsis,
                                    style:
                                        pdfNameStyle,
                                  ),

                                  const SizedBox(
                                    height: 6,
                                  ),

                                  buildFileSize(),

                                  const Spacer(),

                                  Align(
                                    alignment:
                                        AlignmentDirectional.centerEnd,
                                    child:
                                        _buildAlignedMessageMetadata(),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

  // ===========================================================================
  // Local file
  // ===========================================================================

  File? get _localFile {
    if (!_hasLocalSource) {
      return null;
    }

    try {
      final uri =
          Uri.tryParse(
        _source,
      );

      final path =
          uri != null &&
                  uri.scheme == 'file'
              ? uri.toFilePath()
              : _source;

      final file =
          File(
        path,
      );

      if (!file.existsSync()) {
        return null;
      }

      return file;
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // File categories
  // ===========================================================================

  static bool _isAudioExtension(
    String extension,
  ) {
    return const <String>{
      'MP3',
      'M4A',
      'AAC',
      'WAV',
      'OGG',
      'OPUS',
      'FLAC',
      'WMA',
      'AMR',
    }.contains(
      extension,
    );
  }

  static bool _isImageExtension(
    String extension,
  ) {
    return const <String>{
      'JPG',
      'JPEG',
      'PNG',
      'WEBP',
      'GIF',
      'BMP',
      'HEIC',
      'HEIF',
    }.contains(
      extension,
    );
  }

  // ===========================================================================
  // Metadata parsing
  // ===========================================================================

  bool _looksLikeDuration(
    String value,
  ) {
    return RegExp(
      r'^\d{1,3}:\d{2}(?::\d{2})?$',
    ).hasMatch(
      value.trim(),
    );
  }

  bool _looksLikeFileSize(
    String value,
  ) {
    return RegExp(
      r'^\d+(?:\.\d+)?\s*(?:B|KB|MB|GB|TB)$',
      caseSensitive:
          false,
    ).hasMatch(
      value.trim(),
    );
  }

  bool _looksLikeExtension(
    String value,
  ) {
    return value
            .trim()
            .toUpperCase() ==
        _extension;
  }

  // ===========================================================================
  // Filename cleanup
  // ===========================================================================

  static String _cleanFileNameForDisplay(
    String value,
  ) {
    final normalized =
        value
            .trim()
            .replaceAll(
              '\\',
              '/',
            );

    final slash =
        normalized.lastIndexOf(
      '/',
    );

    final baseName =
        slash >= 0
        ? normalized.substring(
            slash + 1,
          )
        : normalized;

    final singleLine =
        baseName
            .replaceAll(
              RegExp(
                r'[\r\n\t]+',
              ),
              ' ',
            )
            .trim();

    return singleLine.isEmpty
        ? 'File'
        : singleLine;
  }

  // ===========================================================================
  // MP3 width helper
  // ===========================================================================

  static String _mp3TitleUsedForWidth(
    String value,
  ) {
    final chars =
        value.runes.toList();

    if (chars.length <=
        _mp3UntruncatedCharacterLimit) {
      return value;
    }

    final visible =
        String.fromCharCodes(
      chars.take(
        _mp3UntruncatedCharacterLimit,
      ),
    ).trimRight();

    return '$visible...';
  }
}

// =============================================================================
// Extension-safe filename
// =============================================================================

class _ExtensionSafeFileName
    extends StatelessWidget {
  const _ExtensionSafeFileName({
    super.key,
    required this.fileName,
    this.maxCharacters,
    required this.style,
    required this.maxWidth,
  });

  final String fileName;
  final int? maxCharacters;

  final TextStyle style;
  final double maxWidth;

  @override
  Widget build(
    BuildContext context,
  ) {
    final cleanFileName =
        _FileMessageBubbleState
            ._cleanFileNameForDisplay(
      fileName,
    );

    final direction =
        Directionality.of(
      context,
    );

    final textScaler =
        MediaQuery.textScalerOf(
      context,
    );

    double textWidth(
      String value,
    ) {
      final painter =
          TextPainter(
        text:
            TextSpan(
          text:
              value,
          style:
              style,
        ),
        maxLines:
            1,
        textDirection:
            direction,
        textScaler:
            textScaler,
      )..layout();

      final width =
          painter.width;

      painter.dispose();

      return width;
    }

    final double safeMaxWidth =
        math.max(
      0.0,
      maxWidth -
          _FileMessageBubbleState
              ._fileNamePaintSafetyWidth,
    );

    final characters =
        cleanFileName.runes.toList();

    final exceedsCharacterLimit =
        maxCharacters != null &&
        characters.length >
            maxCharacters!;

    // =========================================================================
    // Fits naturally
    // =========================================================================

    if (!exceedsCharacterLimit &&
        textWidth(
              cleanFileName,
            ) <=
            safeMaxWidth) {
      return Text(
        cleanFileName,
        maxLines:
            1,
        softWrap:
            false,
        style:
            style,
      );
    }

    // =========================================================================
    // Short MP3 title
    // =========================================================================

    if (maxCharacters != null &&
        !exceedsCharacterLimit) {
      return SizedBox(
        width:
            safeMaxWidth,
        height:
            textScaler.scale(
                  style.fontSize ??
                      14,
                ) *
                (style.height ??
                    1.2),
        child:
            FittedBox(
          fit:
              BoxFit.scaleDown,
          alignment:
              Alignment.centerLeft,
          child:
              Text(
            cleanFileName,
            maxLines:
                1,
            softWrap:
                false,
            style:
                style,
          ),
        ),
      );
    }

    // =========================================================================
    // Preserve extension
    // =========================================================================

    final dot =
        cleanFileName.lastIndexOf(
      '.',
    );

    final extension =
        dot > 0 &&
                dot <
                    cleanFileName.length -
                        1
            ? cleanFileName.substring(
                dot + 1,
              )
            : '';

    /*
     * Example:
     *
     * complete-wrytte-developer-documentation.md
     *
     * becomes:
     *
     * complete-wrytte-deve...md
     *
     * The extension is intentionally kept visible.
     */
    final suffix =
        extension.isEmpty
        ? '...'
        : '...$extension';

    final rawStem =
        extension.isEmpty
        ? cleanFileName
        : cleanFileName
            .substring(
              0,
              dot,
            )
            .trimRight();

    final stemChars =
        rawStem.runes.toList();

    var low =
        0;

    var high =
        math.min(
      stemChars.length,
      maxCharacters ??
          stemChars.length,
    );

    while (low < high) {
      final middle =
          (low + high + 1) ~/
          2;

      final visible =
          String.fromCharCodes(
        stemChars.take(
          middle,
        ),
      ).trimRight();

      final candidate =
          '$visible$suffix';

      if (textWidth(
            candidate,
          ) <=
          safeMaxWidth) {
        low =
            middle;
      } else {
        high =
            middle - 1;
      }
    }

    // =========================================================================
    // IMPORTANT:
    //
    // Do NOT subtract another character.
    //
    // The 4px paint reserve already protects the right boundary.
    // =========================================================================

    final int safeStemLength =
        low;

    final visibleStem =
        String.fromCharCodes(
      stemChars.take(
        safeStemLength,
      ),
    ).trimRight();

    return Text(
      '$visibleStem$suffix',
      maxLines:
          1,
      softWrap:
          false,
      overflow:
          TextOverflow.clip,
      style:
          style,
    );
  }
}

// =============================================================================
// PDF preview background
// =============================================================================

class _PdfPreviewLoadingSurface
    extends StatefulWidget {
  const _PdfPreviewLoadingSurface({
    required this.loading,
    required this.child,
  });

  final bool loading;
  final Widget child;

  @override
  State<_PdfPreviewLoadingSurface>
      createState() =>
          _PdfPreviewLoadingSurfaceState();
}

class _PdfPreviewLoadingSurfaceState
    extends State<_PdfPreviewLoadingSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController
      _controller;

  @override
  void initState() {
    super.initState();

    _controller =
        AnimationController(
      vsync:
          this,
      duration:
          const Duration(
        milliseconds:
            1450,
      ),
    );

    if (widget.loading) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(
    covariant _PdfPreviewLoadingSurface oldWidget,
  ) {
    super.didUpdateWidget(
      oldWidget,
    );

    if (widget.loading &&
        !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.loading &&
        _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return ClipRect(
      child:
          ImageFiltered(
        imageFilter:
            ui.ImageFilter.blur(
          sigmaX:
              14,
          sigmaY:
              14,
        ),
        child:
            Stack(
          fit:
              StackFit.expand,
          alignment:
              Alignment.center,
          children: [
            const DecoratedBox(
              decoration:
                  BoxDecoration(
                gradient:
                    LinearGradient(
                  begin:
                      Alignment.topLeft,
                  end:
                      Alignment.bottomRight,
                  colors: [
                    Color(
                      0xFF242A34,
                    ),
                    Color(
                      0xFF151A22,
                    ),
                    Color(
                      0xFF07090D,
                    ),
                  ],
                  stops: [
                    0,
                    0.56,
                    1,
                  ],
                ),
              ),
            ),

            if (widget.loading)
              LayoutBuilder(
                builder:
                    (
                  context,
                  constraints,
                ) {
                  return AnimatedBuilder(
                    animation:
                        _controller,
                    builder:
                        (
                      context,
                      child,
                    ) {
                      final double width =
                          constraints.hasBoundedWidth
                          ? constraints.maxWidth
                          : 220.0;

                      final double offset =
                          (width *
                                  1.8 *
                                  _controller.value) -
                              width;

                      return Transform.translate(
                        offset:
                            Offset(
                          offset,
                          0,
                        ),
                        child:
                            FractionallySizedBox(
                          widthFactor:
                              0.32,
                          alignment:
                              Alignment.centerLeft,
                          child:
                              DecoratedBox(
                            decoration:
                                BoxDecoration(
                              gradient:
                                  LinearGradient(
                                colors: [
                                  Colors.white.withValues(
                                    alpha:
                                        0,
                                  ),
                                  Colors.white.withValues(
                                    alpha:
                                        0.08,
                                  ),
                                  Colors.white.withValues(
                                    alpha:
                                        0,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),

            Center(
              child:
                  widget.child,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// PDF document icon
// =============================================================================

class _PdfDocumentIcon
    extends StatelessWidget {
  const _PdfDocumentIcon({
    required this.loading,
    required this.downloaded,
    required this.color,
  });

  final bool loading;
  final bool downloaded;

  final Color color;

  @override
  Widget build(
    BuildContext context,
  ) {
    return SizedBox.square(
      dimension:
          50,
      child:
          loading
          ? Center(
              child:
                  SizedBox.square(
                dimension:
                    21,
                child:
                    CircularProgressIndicator(
                  strokeWidth:
                      2,
                  color:
                      color,
                ),
              ),
            )
          : !downloaded
              ? Center(
                  child:
                      WrytteSvgIcon(
                    asset:
                        'assets/svg/Download Save icon.svg',
                    size:
                        27,
                    color:
                        WrytteColors.textPrimary,
                  ),
                )
              : Center(
                  child:
                      SizedBox(
                    width:
                        42,
                    height:
                        48,
                    child:
                        Stack(
                      alignment:
                          Alignment.center,
                      children: [
                        CustomPaint(
                          size:
                              const Size(
                            42,
                            48,
                          ),
                          painter:
                              _PdfDocumentPainter(
                            color,
                          ),
                        ),

                        const Positioned(
                          bottom:
                              10,
                          child:
                              Text(
                            'PDF',
                            style:
                                TextStyle(
                              color:
                                  WrytteColors.textPrimary,
                              fontSize:
                                  8,
                              fontWeight:
                                  FontWeight.w900,
                              height:
                                  1,
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

// =============================================================================
// PDF page painter
// =============================================================================

class _PdfDocumentPainter
    extends CustomPainter {
  const _PdfDocumentPainter(
    this.color,
  );

  final Color color;

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    const double left =
        4.0;

    const double top =
        2.0;

    final double right =
        size.width - 4.0;

    final double bottom =
        size.height - 2.0;

    final double foldX =
        right - 12.0;

    final double foldY =
        top + 12.0;

    final page =
        Path()
          ..moveTo(
            left + 4.0,
            top,
          )
          ..lineTo(
            foldX,
            top,
          )
          ..lineTo(
            right,
            foldY,
          )
          ..lineTo(
            right,
            bottom - 4.0,
          )
          ..quadraticBezierTo(
            right,
            bottom,
            right - 4.0,
            bottom,
          )
          ..lineTo(
            left + 4.0,
            bottom,
          )
          ..quadraticBezierTo(
            left,
            bottom,
            left,
            bottom - 4.0,
          )
          ..lineTo(
            left,
            top + 4.0,
          )
          ..quadraticBezierTo(
            left,
            top,
            left + 4.0,
            top,
          )
          ..close();

    canvas.drawPath(
      page,
      Paint()
        ..color =
            color,
    );

    final fold =
        Path()
          ..moveTo(
            foldX,
            top,
          )
          ..lineTo(
            foldX,
            foldY - 3.0,
          )
          ..quadraticBezierTo(
            foldX,
            foldY,
            foldX + 3.0,
            foldY,
          )
          ..lineTo(
            right,
            foldY,
          )
          ..close();

    final foldColor =
        Color.lerp(
      color,
      Colors.white,
      0.30,
    )!.withValues(
      alpha:
          0.92,
    );

    canvas.drawPath(
      fold,
      Paint()
        ..color =
            foldColor,
    );
  }

  @override
  bool shouldRepaint(
    covariant _PdfDocumentPainter oldDelegate,
  ) {
    return oldDelegate.color !=
        color;
  }
}
