import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/media/models/chat_media_editor_result.dart';
import 'package:wrytte/ui/media/view_models/chat_media_editor_view_model.dart';

import 'package:wrytte/ui/media/widgets/editor/chat_media_editor_bottom_bar.dart';
import 'package:wrytte/ui/media/widgets/editor/chat_media_editor_header.dart';

import 'package:wrytte/ui/media/widgets/editor/crop/chat_media_crop_config.dart';
import 'package:wrytte/ui/media/widgets/editor/emoji/chat_media_emoji_config.dart';
import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_config.dart';
import 'package:wrytte/ui/media/widgets/editor/paint/chat_media_paint_config.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_config.dart';

class ChatMediaEditorView extends StatefulWidget {
  static const int _previewExtent = 384;

  factory ChatMediaEditorView({
    Key? key,
    required MediaAsset asset,
    required MediaLibraryRepository repository,
  }) {
    // Start resolving the original media file immediately.
    //
    // This runs before initState so asset-path resolution can overlap with
    // route construction/animation.
    final sourcePathFuture = repository.loadFilePath(asset.id);

    // Resolve a lightweight preview separately.
    //
    // The preview exists only while the real file path is resolving.
    final previewBytesFuture = _loadPreview(repository, asset.id);

    return ChatMediaEditorView._(
      key: key,
      asset: asset,
      repository: repository,
      sourcePathFuture: sourcePathFuture,
      previewBytesFuture: previewBytesFuture,
      returnOriginalOnClose: true,
    );
  }

  /// Opens the same editor for an already-materialized chat/camera file.
  ///
  /// Keeping this entry point here prevents chat from inventing a second image
  /// editing stack just because its media did not originate in PhotoManager.
  factory ChatMediaEditorView.file({
    Key? key,
    required String path,
    required MediaLibraryRepository repository,
    int width = 0,
    int height = 0,
  }) {
    final normalizedPath = path.trim();
    return ChatMediaEditorView._(
      key: key,
      asset: MediaAsset(
        id: 'local:$normalizedPath',
        kind: MediaKind.image,
        width: width,
        height: height,
        createdAt: DateTime.now(),
      ),
      repository: repository,
      sourcePathFuture: Future<String?>.value(normalizedPath),
      previewBytesFuture: Future<Uint8List?>.value(null),
      returnOriginalOnClose: false,
    );
  }

  const ChatMediaEditorView._({
    super.key,
    required this.asset,
    required this.repository,
    required this.sourcePathFuture,
    required this.previewBytesFuture,
    required this.returnOriginalOnClose,
  });

  final MediaAsset asset;
  final MediaLibraryRepository repository;

  final Future<String?> sourcePathFuture;
  final Future<Uint8List?> previewBytesFuture;
  final bool returnOriginalOnClose;

  static Future<Uint8List?> _loadPreview(
    MediaLibraryRepository repository,
    String assetId,
  ) async {
    try {
      return await repository.loadThumbnail(
        assetId,
        width: _previewExtent,
        height: _previewExtent,
      );
    } catch (_) {
      // Preview failure must never prevent the real photo from opening.
      return null;
    }
  }

  @override
  State<ChatMediaEditorView> createState() => _ChatMediaEditorViewState();
}

class _ChatMediaEditorViewState extends State<ChatMediaEditorView> {
  // Keep the editor toolbar slightly lifted from the bottom edge for a more
  // comfortable reach and to match the edit-screen composition.
  static const double _bottomNavigationBreathingRoom = 80;
  static const double _horizontalChromeInset = 9;

  // ==========================================================================
  // DELIVERY QUALITY
  // ==========================================================================
  //
  // IMPORTANT:
  //
  // This quality selection is intentionally NOT part of ProImageEditor's live
  // editor state.
  //
  // Tapping HD / SD should never:
  //
  // - rebuild the complete image editor,
  // - regenerate the image,
  // - decode the original again,
  // - resize the image,
  // - compress the image,
  // - touch editor history.
  //
  // It is simply a delivery preference until final export.

  final ValueNotifier<bool> _hdQuality = ValueNotifier<bool>(true);

  // Crop and Filter do not behave exactly like normal Paint/Text/Emoji layers.
  //
  // Keep their committed toolbar state separately, but again use notifiers so
  // changing the toolbar indicator never rebuilds the entire editor.
  final ValueNotifier<bool> _cropActive = ValueNotifier<bool>(false);

  final ValueNotifier<bool> _filterActive = ValueNotifier<bool>(false);

  // Captured at the moment final generation begins.
  //
  // If the user somehow taps the quality control while export is already
  // running, the current export still finishes with the profile it started
  // with.
  bool? _exportAsHd;

  final GlobalKey<ProImageEditorState> _editorKey =
      GlobalKey<ProImageEditorState>();

  late final ChatMediaEditorViewModel _model;

  Uint8List? _previewBytes;

  bool _routeClosing = false;
  bool _exporting = false;

  // ==========================================================================
  // IMAGE GENERATION PROFILES
  // ==========================================================================

  /// Editor/final-HD generation profile.
  ///
  /// 3072px keeps a strong high-quality messaging image while avoiding the
  /// huge memory spikes that can come from blindly processing a 6000-8000px
  /// phone photo at full resolution.
  ///
  /// Background generation is OFF intentionally. Otherwise the editor may
  /// repeatedly perform expensive image generation while the user is still
  /// editing.
  static const ImageGenerationConfigs
  _hdGenerationConfigs = ImageGenerationConfigs(
    outputFormat: OutputFormat.jpg,

    maxOutputSize: Size(3072, 3072),

    jpegQuality: 90,

    jpegChroma: JpegChroma.yuv420,

    // Do not keep regenerating the final image after ordinary edit changes.
    //
    // We prefer a smooth editor and perform expensive work once when the user
    // actually completes editing.
    enableBackgroundGeneration: false,

    // Keep generation work away from the UI thread where supported.
    enableIsolateGeneration: true,

    processorConfigs: ProcessorConfigs(
      // One processing worker is intentionally conservative.
      //
      // Export may take slightly longer than saturating every available CPU,
      // but it is much less likely to make a lower-powered phone feel frozen.
      processorMode: ProcessorMode.minimum,
    ),
  );

  /// Standard/SD delivery profile.
  ///
  /// We only apply this AFTER PIE has completed the actual edit.
  static const ImageGenerationConfigs _standardGenerationConfigs =
      ImageGenerationConfigs(
        outputFormat: OutputFormat.jpg,

        maxOutputSize: Size(1600, 1600),

        jpegQuality: 80,

        jpegChroma: JpegChroma.yuv420,

        enableBackgroundGeneration: false,
        enableIsolateGeneration: true,

        processorConfigs: ProcessorConfigs(
          processorMode: ProcessorMode.minimum,
        ),
      );

  // ==========================================================================
  // MATERIAL_UI THEME
  // ==========================================================================

  late final material_ui.ThemeData _editorTheme = material_ui.ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: WrytteColors.background,
    colorScheme: material_ui.ColorScheme.fromSeed(
      seedColor: WrytteColors.primary,
      brightness: Brightness.dark,
      surface: WrytteColors.background,
    ),
  );

  // ==========================================================================
  // PRO IMAGE EDITOR CONFIGURATION
  // ==========================================================================

  late final ProImageEditorConfigs _configs = ProImageEditorConfigs(
    theme: _editorTheme,

    // =========================================================================
    // MAIN EDITOR
    // =========================================================================
    mainEditor: MainEditorConfigs(
      enableZoom: true,
      enableDoubleTapZoom: true,

      editorMinScale: 1,
      editorMaxScale: 8,

      // Wrytte owns the visible Back control.
      enableCloseButton: false,

      // Main image remains edge-to-edge.
      //
      // Wrytte's overlay chrome handles physical system safe areas.
      safeArea: const EditorSafeArea.none(),

      interactiveViewerClipBehavior: Clip.none,

      tools: const [
        SubEditorMode.cropRotate,
        SubEditorMode.paint,
        SubEditorMode.text,
        SubEditorMode.emoji,
        SubEditorMode.tune,
        SubEditorMode.filter,
        SubEditorMode.blur,
      ],

      style: const MainEditorStyle(
        background: WrytteColors.background,

        appBarBackground: Colors.transparent,
        bottomBarBackground: Colors.transparent,

        appBarColor: WrytteColors.textPrimary,
        bottomBarColor: WrytteColors.textPrimary,
      ),

      widgets: MainEditorWidgets(
        // The package default uses the root navigator for this dialog. Our
        // editor supplies localizations below that navigator, so open the
        // warning on the editor's nearest navigator instead.
        closeWarningDialog: (editor) async {
          return await showDialog<bool>(
                context: editor.context,
                useRootNavigator: false,
                builder: (dialogContext) {
                  return AlertDialog(
                    title: const Text('Close editor?'),
                    content: const Text(
                      'Your changes will not be saved.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('Discard'),
                      ),
                    ],
                  );
                },
              ) ??
              false;
        },

        // ---------------------------------------------------------------------
        // REMOVE PACKAGE MAIN CHROME
        // ---------------------------------------------------------------------
        appBar: (editor, rebuildStream) => null,

        bottomBar: (editor, rebuildStream, key) => null,

        // ---------------------------------------------------------------------
        // WRYTTE MAIN CHROME
        // ---------------------------------------------------------------------
        bodyItems: (editor, rebuildStream) {
          return <ReactiveWidget<Widget>>[
            // ================================================================
            // HEADER
            // ================================================================
            ReactiveWidget<Widget>(
              stream: rebuildStream,
              builder: (overlayContext) {
                // Every sub-editor owns its own interface.
                //
                // Never show the main controls underneath Crop / Draw / Text /
                // Filter.
                if (editor.isSubEditorOpen) {
                  return const SizedBox.shrink();
                }

                final topInset = MediaQuery.viewPaddingOf(overlayContext).top;

                return PositionedDirectional(
                  top: 0,
                  start: 0,
                  end: 0,
                  height: topInset + ChatMediaEditorHeader.contentHeight,
                  child: ChatMediaEditorHeader(onBack: editor.closeEditor),
                );
              },
            ),

            // ================================================================
            // MAIN BOTTOM BAR
            // ================================================================
            ReactiveWidget<Widget>(
              stream: rebuildStream,
              builder: (overlayContext) {
                if (editor.isSubEditorOpen) {
                  return const SizedBox.shrink();
                }

                return PositionedDirectional(
                  start: _horizontalChromeInset,
                  end: _horizontalChromeInset,
                  bottom: 0,

                  // =========================================================
                  // IMPORTANT PERFORMANCE DETAIL
                  // =========================================================
                  //
                  // These ValueListenableBuilders rebuild only our small
                  // toolbar when Crop/Filter/HD state changes.
                  //
                  // We DO NOT call ChatMediaEditorView.setState merely because
                  // the user taps HD -> SD. Therefore ProImageEditor itself is
                  // not rebuilt.
                  child: SafeArea(
                    top: false,
                    left: false,
                    right: false,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        bottom: _bottomNavigationBreathingRoom,
                      ),
                      child: SizedBox(
                        height: ChatMediaEditorBottomBar.height,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _cropActive,
                          builder: (context, cropActive, child) {
                            return ValueListenableBuilder<bool>(
                              valueListenable: _filterActive,
                              builder: (context, filterActive, child) {
                                return ValueListenableBuilder<bool>(
                                  valueListenable: _hdQuality,
                                  builder: (context, isHd, child) {
                                    return ChatMediaEditorBottomBar(
                                      editor: editor,
                                      cropActive: cropActive,
                                      filterActive: filterActive,
                                      isHd: isHd,
                                      onQualityChanged: (nextIsHd) {
                                        if (_exporting ||
                                            _hdQuality.value == nextIsHd) {
                                          return;
                                        }
                                        _hdQuality.value = nextIsHd;
                                      },
                                    );
                                  },
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ];
        },
      ),
    ),

    // =========================================================================
    // CROP
    // =========================================================================
    cropRotateEditor: buildChatMediaCropEditorConfigs(
      onApplied: _handleCropApplied,
      onDiscarded: _closeActiveSubEditor,
    ),

    // =========================================================================
    // DRAW
    // =========================================================================
    paintEditor: buildChatMediaPaintEditorConfigs(
      onDiscarded: _closeActiveSubEditor,
    ),

    // =========================================================================
    // TEXT
    // =========================================================================
    textEditor: buildChatMediaTextEditorConfigs(
      onDiscarded: _closeActiveSubEditor,
    ),

    // =========================================================================
    // EMOJI / STICKERS
    // =========================================================================
    emojiEditor: buildChatMediaEmojiEditorConfigs(),

    // =========================================================================
    // FILTER
    // =========================================================================
    filterEditor: buildChatMediaFilterEditorConfigs(
      onApplied: _handleFilterApplied,
      onDiscarded: _closeActiveSubEditor,
    ),

    // =========================================================================
    // FINAL IMAGE GENERATION
    // =========================================================================
    //
    // Always let the editor produce one bounded high-quality result.
    //
    // HD:
    //   use those bytes directly.
    //
    // Standard/SD:
    //   perform ONE additional delivery conversion when editing is finished.
    //
    // We never swap this configuration live when the user taps the quality
    // control because that would couple a cheap UI choice to expensive editor
    // reconstruction.
    imageGeneration: _hdGenerationConfigs,
  );

  // ==========================================================================
  // CALLBACKS
  // ==========================================================================

  late final ProImageEditorCallbacks _callbacks = ProImageEditorCallbacks(
    onImageEditingStarted: _handleImageEditingStarted,

    onImageEditingComplete: _completeImageEditing,

    onCloseEditor: _handleEditorClosed,
  );

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  @override
  void initState() {
    super.initState();

    _model = ChatMediaEditorViewModel(
      asset: widget.asset,
      repository: widget.repository,

      // File resolution was already started in the factory constructor.
      prestartedSourcePath: widget.sourcePathFuture,
    )..addListener(_handleModelChanged);

    unawaited(_model.initialize());

    unawaited(_resolvePreview());
  }

  @override
  void dispose() {
    _model
      ..removeListener(_handleModelChanged)
      ..dispose();

    _cropActive.dispose();
    _filterActive.dispose();
    _hdQuality.dispose();

    super.dispose();
  }

  // ==========================================================================
  // CROP STATE
  // ==========================================================================

  void _handleCropApplied(bool sessionChanged) {
    if (!mounted || !sessionChanged) {
      return;
    }

    // ValueNotifier updates only the small main toolbar once Crop closes.
    _cropActive.value = true;
  }

  // ==========================================================================
  // FILTER STATE
  // ==========================================================================

  void _handleFilterApplied(bool active) {
    if (!mounted) {
      return;
    }

    // If Original is selected, the Filter icon returns to inactive.
    //
    // Again: no complete editor rebuild.
    _filterActive.value = active;
  }

  void _closeActiveSubEditor() {
    debugPrint('[PAINTDBG][PARENT] closeActiveSubEditor called');
    // Use Pro Image Editor's main-state API. Calling `close()` only on a
    // nested editor can fire its callback without removing the nested route on
    // recent package versions, leaving the user on the discarded tool screen.
    _editorKey.currentState?.closeSubEditor();
  }

  // ==========================================================================
  // LIGHTWEIGHT OPENING PREVIEW
  // ==========================================================================

  Future<void> _resolvePreview() async {
    final bytes = await widget.previewBytesFuture;

    if (!mounted) {
      return;
    }

    // The real editor is already ready.
    //
    // Never retain duplicate preview bytes after that point.
    if (_model.loadState == ChatMediaEditorLoadState.ready) {
      return;
    }

    if (bytes == null || bytes.isEmpty) {
      return;
    }

    setState(() {
      _previewBytes = bytes;
    });
  }

  void _handleModelChanged() {
    if (!mounted) {
      return;
    }

    // ------------------------------------------------------------------------
    // ONE IMAGE SURFACE AT A TIME
    // ------------------------------------------------------------------------
    //
    // Loading:
    //
    //   lightweight thumbnail
    //
    // Ready:
    //
    //   ProImageEditor.file(...)
    //
    // They never overlap.

    if (_model.loadState == ChatMediaEditorLoadState.ready) {
      _previewBytes = null;
    }

    setState(() {});
  }

  // ==========================================================================
  // FINAL EXPORT
  // ==========================================================================

  void _handleImageEditingStarted() {
    if (!mounted || _routeClosing || _exporting) {
      return;
    }

    // Freeze this export's quality selection.
    _exportAsHd = _hdQuality.value;

    setState(() {
      _exporting = true;
    });
  }

  Future<void> _completeImageEditing(Uint8List editorBytes) async {
    final sourcePath = _model.sourcePath;

    if (sourcePath == null || _routeClosing) {
      return;
    }

    try {
      // ================================================================
      // QUALITY IS APPLIED HERE — ONCE
      // ================================================================
      //
      // HD:
      //   PIE already generated the bounded HD JPEG. No second conversion.
      //
      // Standard:
      //   downsize/re-encode once for delivery.
      //
      // Nothing expensive happened when the user merely tapped HD / SD.

      final shouldUseHd = _exportAsHd ?? _hdQuality.value;

      final deliveryBytes = shouldUseHd
          ? editorBytes
          : await _buildStandardDeliveryImage(editorBytes);

      if (!mounted || _routeClosing) {
        return;
      }

      final directory = await getTemporaryDirectory();

      if (!mounted || _routeClosing) {
        return;
      }

      final qualitySuffix = shouldUseHd ? 'hd' : 'standard';

      final editedFilePath =
          '${directory.path}'
          '${Platform.pathSeparator}'
          'wrytte_edit_'
          '$qualitySuffix'
          '_${DateTime.now().microsecondsSinceEpoch}'
          '.jpg';

      await File(editedFilePath).writeAsBytes(deliveryBytes, flush: true);

      if (!mounted || _routeClosing) {
        return;
      }

      _popResult(
        ChatMediaEditorResult(
          assetId: widget.asset.id,

          originalFilePath: sourcePath,

          editedFilePath: editedFilePath,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to save edited image: $error');

      debugPrintStack(stackTrace: stackTrace);

      if (!mounted || _routeClosing) {
        return;
      }

      _exportAsHd = null;

      setState(() {
        _exporting = false;
      });

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('The edited photo could not be saved.')),
      );
    }
  }

  /// Converts the already-completed editor result into Wrytte's lightweight
  /// Standard delivery profile.
  ///
  /// This runs only once at final completion.
  ///
  /// If conversion ever fails, returning [sourceBytes] is safer than losing
  /// the user's completed edit.
  Future<Uint8List> _buildStandardDeliveryImage(Uint8List sourceBytes) async {
    ui.Codec? codec;
    ui.Image? image;

    try {
      // Decode the completed editor JPEG.
      //
      // This is intentionally deferred until final send/export. It is never
      // performed while the user is simply switching the toolbar preference.
      codec = await ui.instantiateImageCodec(sourceBytes);

      final frame = await codec.getNextFrame();

      image = frame.image;

      // Pro Image Editor exposes this helper for converting a ui.Image using
      // ImageGenerationConfigs. The Standard profile handles aspect-preserving
      // maximum output size and JPEG encoding.
      final standardBytes = await generateHighQualityImage(
        image,
        configs: _standardGenerationConfigs,
      );

      if (standardBytes == null || standardBytes.isEmpty) {
        return sourceBytes;
      }

      return standardBytes;
    } catch (error, stackTrace) {
      debugPrint('Standard delivery conversion failed: $error');

      debugPrintStack(stackTrace: stackTrace);

      // Never throw away an otherwise valid completed edit because optional
      // delivery compression failed.
      return sourceBytes;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  // ==========================================================================
  // EDITOR CLOSE
  // ==========================================================================

  void _handleEditorClosed(EditorMode mode) {
    if (_routeClosing) {
      return;
    }

    // Crop / Draw / Text / Filter close back into the main editor.
    //
    // Only closing EditorMode.main should dismiss this whole route.
    if (mode != EditorMode.main) {
      return;
    }

    final sourcePath = _model.sourcePath;

    if (sourcePath == null || !widget.returnOriginalOnClose) {
      _popWithoutResult();
      return;
    }

    _popResult(
      ChatMediaEditorResult(
        assetId: widget.asset.id,

        originalFilePath: sourcePath,

        // No newly-generated result was requested.
        editedFilePath: null,
      ),
    );
  }

  // ==========================================================================
  // ROUTE HELPERS
  // ==========================================================================

  void _popResult(ChatMediaEditorResult result) {
    if (!mounted || _routeClosing) {
      return;
    }

    _routeClosing = true;

    Navigator.of(context).pop(result);
  }

  void _popWithoutResult() {
    if (!mounted || _routeClosing) {
      return;
    }

    _routeClosing = true;

    Navigator.of(context).pop();
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    return PopScope(
        // Prevent Android/system Back from killing the route while the final
        // generated image is being converted/written.
        canPop: !_exporting,

        child: ColoredBox(
          color: WrytteColors.background,

          child: switch (_model.loadState) {
            ChatMediaEditorLoadState.ready => _buildEditor(),

            ChatMediaEditorLoadState.failed => _buildError(),

            ChatMediaEditorLoadState.idle ||
            ChatMediaEditorLoadState.loading => _buildOpeningPreview(),
          },
        ),
    );
  }

  // ==========================================================================
  // REAL EDITOR
  // ==========================================================================

  Widget _buildEditor() {
    final sourcePath = _model.sourcePath!;

    debugPrint(
      '[LOCDBG][ChatMediaEditorView] '
      'flutterMaterialLocalizations='
      '${Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) != null} '
      'locale=${Localizations.maybeLocaleOf(context)}',
    );

    // This is the sole full-resolution media surface once loading completes.
    //
    // There is no preview underneath it and no duplicate image layer.

    return ProImageEditor.file(
      File(sourcePath),

      key: _editorKey,

      configs: _configs,

      callbacks: _callbacks,
    );
  }

  // ==========================================================================
  // OPENING PREVIEW
  // ==========================================================================

  Widget _buildOpeningPreview() {
    final topInset = MediaQuery.viewPaddingOf(context).top;

    return ColoredBox(
      color: WrytteColors.background,

      child: Stack(
        fit: StackFit.expand,

        children: [
          if (_previewBytes != null)
            Positioned.fill(
              child: RepaintBoundary(
                child: Image.memory(
                  _previewBytes!,

                  fit: BoxFit.contain,

                  filterQuality: FilterQuality.low,

                  gaplessPlayback: true,
                ),
              ),
            ),

          PositionedDirectional(
            top: 0,

            start: 0,

            end: 0,

            height: topInset + ChatMediaEditorHeader.contentHeight,

            child: ChatMediaEditorHeader(onBack: _popWithoutResult),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // ERROR STATE
  // ==========================================================================

  Widget _buildError() {
    final topInset = MediaQuery.viewPaddingOf(context).top;

    return Scaffold(
      backgroundColor: WrytteColors.background,

      body: Stack(
        children: [
          PositionedDirectional(
            top: 0,

            start: 0,

            end: 0,

            height: topInset + ChatMediaEditorHeader.contentHeight,

            child: ChatMediaEditorHeader(onBack: _popWithoutResult),
          ),

          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),

              child: Column(
                mainAxisSize: MainAxisSize.min,

                children: [
                  const Icon(
                    Icons.broken_image_outlined,

                    size: 38,

                    color: WrytteColors.textMuted,
                  ),

                  const SizedBox(height: 14),

                  Text(
                    _model.errorMessage ?? 'This photo could not be opened.',

                    textAlign: TextAlign.center,

                    style: const TextStyle(
                      color: WrytteColors.textSecondary,

                      fontFamily: WrytteTypography.primaryFontFamily,

                      fontSize: 15,

                      height: 1.3,
                    ),
                  ),

                  const SizedBox(height: 18),

                  FilledButton(
                    onPressed: () {
                      unawaited(_model.retry());
                    },

                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
