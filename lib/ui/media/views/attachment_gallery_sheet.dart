import 'dart:async';

import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:wrytte/domain/models/attachment_gallery_config.dart';

import 'package:wrytte/domain/models/attachment_gallery_result.dart';

import 'package:wrytte/domain/models/attachment_contact.dart';

import 'package:wrytte/domain/models/media_album.dart';

import 'package:wrytte/domain/models/media_asset.dart';

import 'package:wrytte/domain/models/media_library_access.dart';

import 'package:wrytte/domain/models/picked_attachment_file.dart';

import 'package:wrytte/domain/models/poll_attachment_draft.dart';

import 'package:wrytte/domain/repositories/attachment_picker_repository.dart';

import 'package:wrytte/domain/repositories/media_library_repository.dart';

import 'package:wrytte/ui/camera/models/camera_route_result.dart';

import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/routing/expanding_surface_route.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/media/view_models/attachment_gallery_view_model.dart';

import 'package:wrytte/ui/media/models/chat_attachment_tab.dart';

import 'package:wrytte/ui/media/models/chat_media_editor_result.dart';
import 'package:wrytte/ui/media/views/chat_media_editor_view.dart';

import 'package:wrytte/ui/media/widgets/album_menu.dart';

import 'package:wrytte/ui/media/widgets/attachment_grid.dart';

import 'package:wrytte/ui/media/widgets/attachment_sheet_header.dart';

import 'package:wrytte/ui/media/widgets/chat_attachment_category_bar.dart';

import 'package:wrytte/ui/media/widgets/chat_attachment_content.dart';

import 'package:wrytte/ui/media/widgets/chat_attachment_send_bar.dart';

import 'package:wrytte/ui/media/widgets/gallery_state_view.dart';

import 'package:wrytte/ui/media/widgets/media_gallery_tokens.dart';

typedef AttachmentCameraLauncher =
    Future<CameraRouteResult?> Function(
      ExpandingSurfaceOrigin origin,

      MediaAsset? latestAsset,
    );

typedef AttachmentMediaLauncher =
    Future<AttachmentGalleryResult?> Function(
      MediaAsset asset,

      ExpandingSurfaceOrigin origin,
    );

/// Supplies an externally owned camera surface without coupling the media

/// gallery to camera plugin types or camera lifecycle operations.

typedef AttachmentCameraPreviewBuilder = Widget Function(BuildContext context);

Future<AttachmentGalleryResult?> showWrytteAttachmentGallery(
  BuildContext context, {

  required AttachmentGalleryConfig config,

  required MediaLibraryRepository repository,

  AttachmentCameraLauncher? onCameraRequested,

  AttachmentMediaLauncher? onMediaRequested,

  AttachmentCameraPreviewBuilder? cameraPreviewBuilder,

  AttachmentPickerRepository? pickerRepository,

  Future<void> Function()? onRemovePhoto,
}) {
  final disableAnimations = MediaQuery.disableAnimationsOf(context);

  return showModalBottomSheet<AttachmentGalleryResult>(
    context: context,

    useRootNavigator: true,

    useSafeArea: false,

    isScrollControlled: true,

    isDismissible: true,

    enableDrag: false,

    backgroundColor: Colors.transparent,

    barrierColor: Colors.black.withValues(alpha: .48),

    sheetAnimationStyle: AnimationStyle(
      duration: disableAnimations
          ? Duration.zero
          : MediaGalleryTokens.openDuration,

      reverseDuration: disableAnimations
          ? Duration.zero
          : MediaGalleryTokens.closeDuration,
    ),

    builder: (_) => ChangeNotifierProvider(
      create: (_) =>
          AttachmentGalleryViewModel(repository, config: config)..initialize(),

      child: _AttachmentGallerySheet(
        repository: repository,

        config: config,

        onCameraRequested: onCameraRequested,

        onMediaRequested: onMediaRequested,

        cameraPreviewBuilder: cameraPreviewBuilder,

        pickerRepository: pickerRepository,

        onRemovePhoto: onRemovePhoto,
      ),
    ),
  );
}

class _AttachmentGallerySheet extends StatefulWidget {
  const _AttachmentGallerySheet({
    required this.repository,

    required this.config,

    this.onCameraRequested,

    this.onMediaRequested,

    this.cameraPreviewBuilder,

    this.pickerRepository,

    this.onRemovePhoto,
  });

  final MediaLibraryRepository repository;

  final AttachmentGalleryConfig config;

  final AttachmentCameraLauncher? onCameraRequested;

  final AttachmentMediaLauncher? onMediaRequested;

  final AttachmentCameraPreviewBuilder? cameraPreviewBuilder;

  final AttachmentPickerRepository? pickerRepository;

  final Future<void> Function()? onRemovePhoto;

  @override
  State<_AttachmentGallerySheet> createState() =>
      _AttachmentGallerySheetState();
}

class _AttachmentGallerySheetState extends State<_AttachmentGallerySheet>
    with SingleTickerProviderStateMixin {
  final _sheetController = DraggableScrollableController();

  final _sheetExpansionProgress = ValueNotifier<double>(0);

  final _galleryScrollProgress = ValueNotifier<double>(0);

  late final AnimationController _menuController;

  late final Animation<double> _menuOpacity;

  late final AppLifecycleListener _lifecycleListener;

  bool _menuMounted = false;

  bool _dismissing = false;

  bool _headerDragWasDownward = false;

  ScrollController? _galleryScrollController;

  final _captionController = TextEditingController();

  ChatAttachmentTab _tab = ChatAttachmentTab.gallery;

  List<PickedAttachmentFile> _files = const [];

  final Set<String> _selectedFilePaths = {};

  List<AttachmentContact> _contacts = const [];

  final Set<String> _selectedContactIds = {};

  bool _pickingFiles = false;

  bool _loadingContacts = false;

  bool _contactsAccessDenied = false;

  bool _contactsLoaded = false;

  PollAttachmentDraft? _poll;

  @override
  void initState() {
    super.initState();

    _sheetExpansionProgress.value =
        widget.config.initialExtent == AttachmentSheetExtent.expanded ? 1 : 0;

    _menuController = AnimationController(
      vsync: this,

      duration: MediaGalleryTokens.menuDuration,

      reverseDuration: MediaGalleryTokens.menuReverseDuration,
    );

    _sheetController.addListener(_syncSheetExpansion);

    final curve = CurvedAnimation(
      parent: _menuController,

      curve: Curves.easeOutCubic,

      reverseCurve: Curves.easeInCubic,
    );

    _menuOpacity = curve;

    _lifecycleListener = AppLifecycleListener(
      onResume: () {
        if (mounted) {
          unawaited(context.read<AttachmentGalleryViewModel>().reconcile());
        }
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final disabled = MediaQuery.disableAnimationsOf(context);

    _menuController.duration = disabled
        ? Duration.zero
        : MediaGalleryTokens.menuDuration;

    _menuController.reverseDuration = disabled
        ? Duration.zero
        : MediaGalleryTokens.menuReverseDuration;
  }

  @override
  void dispose() {
    _galleryScrollController?.removeListener(_syncGalleryScroll);

    _captionController.dispose();

    _sheetController.removeListener(_syncSheetExpansion);

    _lifecycleListener.dispose();

    _sheetExpansionProgress.dispose();

    _galleryScrollProgress.dispose();

    _menuController.dispose();

    _sheetController.dispose();

    super.dispose();
  }

  Future<void> _toggleAlbumMenu() async {
    if (_menuMounted) {
      await _closeAlbumMenu();

      return;
    }

    if (_sheetController.isAttached &&
        _sheetController.size < MediaGalleryTokens.expandedExtent - .02) {
      await _sheetController.animateTo(
        MediaGalleryTokens.expandedExtent,

        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),

        curve: Curves.easeOutCubic,
      );

      if (!mounted) return;

      await WidgetsBinding.instance.endOfFrame;
    }

    setState(() => _menuMounted = true);

    await _menuController.forward(from: 0);
  }

  Future<void> _closeAlbumMenu() async {
    if (!_menuMounted) return;

    await _menuController.reverse();

    if (mounted) {
      setState(() => _menuMounted = false);
    }
  }

  Future<void> _selectAlbum(MediaAlbum album) async {
    await _closeAlbumMenu();

    if (!mounted) return;

    await context.read<AttachmentGalleryViewModel>().changeAlbum(album);
  }

  void _dismissSheet() {
    if (!mounted || _dismissing) return;

    _dismissing = true;

    Navigator.of(context).pop();
  }

  void _bindGalleryScrollController(ScrollController controller) {
    if (identical(_galleryScrollController, controller)) return;

    _galleryScrollController?.removeListener(_syncGalleryScroll);

    _galleryScrollController = controller;

    controller.addListener(_syncGalleryScroll);
  }

  void _syncGalleryScroll() {
    final controller = _galleryScrollController;

    if (controller == null || !controller.hasClients) return;

    final progress = (controller.offset / 28).clamp(0.0, 1.0);

    if ((_galleryScrollProgress.value - progress).abs() > .001) {
      _galleryScrollProgress.value = progress;
    }
  }

  void _syncSheetExpansion() {
    if (!_sheetController.isAttached) return;

    final progress =
        ((_sheetController.size - MediaGalleryTokens.compactExtent) /
                (MediaGalleryTokens.expandedExtent -
                    MediaGalleryTokens.compactExtent))
            .clamp(0.0, 1.0);

    if ((_sheetExpansionProgress.value - progress).abs() > .001) {
      _sheetExpansionProgress.value = progress;
    }
  }

  void _handleHeaderDragStart(DragStartDetails details) {
    _headerDragWasDownward = false;

    if (_menuMounted) unawaited(_closeAlbumMenu());
  }

  void _handleHeaderDragUpdate(DragUpdateDetails details) {
    if (!_sheetController.isAttached) return;

    final delta = details.primaryDelta ?? 0;

    if (delta > 0) _headerDragWasDownward = true;

    final height = MediaQuery.sizeOf(context).height;

    if (height <= 0) return;

    _sheetController.jumpTo(
      (_sheetController.size - (delta / height)).clamp(
        MediaGalleryTokens.minExtent,

        MediaGalleryTokens.expandedExtent,
      ),
    );
  }

  void _handleHeaderDragEnd(DragEndDetails details) {
    if (!_sheetController.isAttached || _dismissing) return;

    final size = _sheetController.size;

    final velocity = details.primaryVelocity ?? 0;

    final shouldDismiss =
        _headerDragWasDownward &&
        (size <= MediaGalleryTokens.dismissExtent ||
            (velocity > 1200 && size < MediaGalleryTokens.compactExtent));

    if (shouldDismiss) {
      _dismissSheet();

      return;
    }

    final midpoint =
        (MediaGalleryTokens.compactExtent + MediaGalleryTokens.expandedExtent) /
        2;

    final shouldExpand = velocity < -700 || size > midpoint;

    unawaited(
      _sheetController.animateTo(
        shouldExpand
            ? MediaGalleryTokens.expandedExtent
            : MediaGalleryTokens.compactExtent,

        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 280),

        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _handleHeaderDragCancel() {
    _headerDragWasDownward = false;
  }

  void _confirm() {
    final model = context.read<AttachmentGalleryViewModel>();

    final result = switch (_tab) {
      ChatAttachmentTab.gallery => model.hasSelection
          ? model.result.withCaption(_captionController.text)
          : null,

      ChatAttachmentTab.file =>
        _selectedFilePaths.isEmpty
            ? null
            : AttachmentGalleryResult.files(
                _files
                    .where((file) => _selectedFilePaths.contains(file.path))
                    .toList(growable: false),
              ),

      ChatAttachmentTab.contact =>
        _selectedContactIds.isEmpty
            ? null
            : AttachmentGalleryResult.contacts(
                _contacts
                    .where(
                      (contact) => _selectedContactIds.contains(contact.id),
                    )
                    .toList(growable: false),
              ),

      ChatAttachmentTab.poll =>
        _poll == null ? null : AttachmentGalleryResult.poll(_poll),

      ChatAttachmentTab.location => null,
    };

    if (result != null) Navigator.of(context).pop(result);
  }

  int _selectionCount(AttachmentGalleryViewModel model) => switch (_tab) {
    ChatAttachmentTab.gallery => model.selectedIds.length,

    ChatAttachmentTab.file => _selectedFilePaths.length,

    ChatAttachmentTab.contact => _selectedContactIds.length,

    ChatAttachmentTab.poll => _poll == null ? 0 : 1,

    ChatAttachmentTab.location => 0,
  };

  Future<void> _selectTab(ChatAttachmentTab tab) async {
    if (_tab == tab) return;

    if (_menuMounted) await _closeAlbumMenu();

    if (!mounted) return;

    setState(() => _tab = tab);

    _galleryScrollProgress.value = 0;

    if (_sheetController.isAttached &&
        _sheetController.size < MediaGalleryTokens.expandedExtent - .02) {
      unawaited(
        _sheetController.animateTo(
          MediaGalleryTokens.expandedExtent,

          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 230),

          curve: Curves.easeOutCubic,
        ),
      );
    }

    if (tab == ChatAttachmentTab.contact && !_contactsLoaded) {
      unawaited(_loadContacts());
    }
  }

  Future<void> _pickFiles({required bool audioOnly}) async {
    final picker = widget.pickerRepository;

    if (picker == null || _pickingFiles) return;

    setState(() => _pickingFiles = true);

    try {
      final picked = await picker.pickFiles(audioOnly: audioOnly);

      if (!mounted) return;

      final byPath = {for (final file in _files) file.path: file};

      for (final file in picked) {
        byPath[file.path] = file;
      }

      setState(() {
        _files = byPath.values.toList(growable: false);

        final room =
            widget.config.maxSelectionCount - _selectedFilePaths.length;

        _selectedFilePaths.addAll(
          picked.take(room.clamp(0, picked.length)).map((file) => file.path),
        );
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The file picker could not be opened.')),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingFiles = false);
    }
  }

  void _toggleFile(PickedAttachmentFile file) {
    setState(() {
      if (!_selectedFilePaths.remove(file.path) &&
          _selectedFilePaths.length < widget.config.maxSelectionCount) {
        _selectedFilePaths.add(file.path);
      }
    });
  }

  Future<void> _loadContacts() async {
    final picker = widget.pickerRepository;

    if (picker == null || _loadingContacts) return;

    setState(() => _loadingContacts = true);

    try {
      final page = await picker.loadContacts();

      if (!mounted) return;

      setState(() {
        _contacts = page.contacts;

        _contactsAccessDenied = page.accessDenied;

        _contactsLoaded = true;
      });
    } finally {
      if (mounted) setState(() => _loadingContacts = false);
    }
  }

  void _toggleContact(AttachmentContact contact) {
    setState(() {
      if (!_selectedContactIds.remove(contact.id) &&
          _selectedContactIds.length < widget.config.maxSelectionCount) {
        _selectedContactIds.add(contact.id);
      }
    });
  }

  void _chooseLocation(String label) {
    Navigator.of(context).pop(AttachmentGalleryResult.location(label));
  }

  Widget _buildContent(ScrollController scrollController) {
    if (_tab == ChatAttachmentTab.file) {
      return FileAttachmentContent(
        scrollController: scrollController,

        files: _files,

        selectedPaths: _selectedFilePaths,

        loading: _pickingFiles,

        onChooseFiles: () => _pickFiles(audioOnly: false),

        onChooseAudio: () => _pickFiles(audioOnly: true),

        onToggle: _toggleFile,
      );
    }

    if (_tab == ChatAttachmentTab.contact) {
      return ContactAttachmentContent(
        scrollController: scrollController,

        contacts: _contacts,

        selectedIds: _selectedContactIds,

        loading: _loadingContacts,

        accessDenied: _contactsAccessDenied,

        onRetry: _loadContacts,

        onOpenSettings: () => widget.pickerRepository?.openContactsSettings(),

        onToggle: _toggleContact,
      );
    }

    if (_tab == ChatAttachmentTab.location) {
      return LocationAttachmentContent(
        scrollController: scrollController,

        onChoose: _chooseLocation,
      );
    }

    if (_tab == ChatAttachmentTab.poll) {
      return PollAttachmentContent(
        scrollController: scrollController,

        onChanged: (poll) => setState(() => _poll = poll),
      );
    }

    return _buildGalleryContent(scrollController);
  }

  Widget _buildGalleryContent(ScrollController scrollController) {
    return Selector<AttachmentGalleryViewModel, _ContentData>(
      selector: (_, model) =>
          _ContentData(access: model.access, contentState: model.contentState),

      builder: (context, data, _) {
        if (data.contentState == GalleryContentState.ready ||
            data.contentState == GalleryContentState.initialLoading) {
          return AttachmentGrid(
            scrollController: scrollController,

            repository: widget.repository,

            showCameraPlaceholder: widget.config.showCameraPlaceholder,

            showSelectionIndicators:
                widget.config.purpose != AttachmentPurpose.profilePhoto,

            expansionProgress: _sheetExpansionProgress,

            initialLoading:
                data.contentState == GalleryContentState.initialLoading,

            cameraPreview: widget.cameraPreviewBuilder?.call(context),

            onCameraPressed: widget.onCameraRequested == null
                ? null
                : _openCamera,

            onAssetPressed: _openMedia,
          );
        }

        final model = context.read<AttachmentGalleryViewModel>();

        return GalleryStateView(
          access: data.access,

          isLoading: data.contentState == GalleryContentState.initialLoading,

          failed: data.contentState == GalleryContentState.failed,

          onRetry: model.retry,

          onOpenSettings: model.openSettings,

          onManageLimited: model.manageLimitedAccess,
        );
      },
    );
  }

  Future<void> _openCamera(ExpandingSurfaceOrigin origin) async {
    final launcher = widget.onCameraRequested;

    if (launcher == null) return;

    final model = context.read<AttachmentGalleryViewModel>();

    final firstAsset = model.assets.firstOrNull;

    final result = await launcher(origin, firstAsset);

    if (!mounted || result == null) return;

    if (result.action == CameraRouteAction.returnToGallery) {
      await _expandSheet();

      return;
    }

    final capture = result.capture;

    if (capture == null) return;

    Navigator.of(context).pop(AttachmentGalleryResult.camera(capture));
  }

  Future<void> _expandSheet() async {
    if (!_sheetController.isAttached ||
        _sheetController.size >= MediaGalleryTokens.expandedExtent - .002) {
      return;
    }

    await _sheetController.animateTo(
      MediaGalleryTokens.expandedExtent,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openMedia(
    MediaAsset asset,
    ExpandingSurfaceOrigin origin,
  ) async {
    // Keep the dedicated profile-photo flow untouched.
    if (widget.config.purpose == AttachmentPurpose.profilePhoto) {
      final launcher = widget.onMediaRequested;
      if (launcher == null) return;

      final result = await launcher(asset, origin);
      if (!mounted || result == null) return;

      Navigator.of(context).pop(result);
      return;
    }

    // Video editing is intentionally not mixed into the image-editor setup.
    // Preserve the existing external video flow when one is available.
    if (asset.kind == MediaKind.video) {
      final launcher = widget.onMediaRequested;

      if (launcher != null) {
        final result = await launcher(asset, origin);
        if (!mounted || result == null) return;

        Navigator.of(context).pop(result);
        return;
      }

      context.read<AttachmentGalleryViewModel>().toggleSelection(asset);
      return;
    }

    // Push immediately. The editor resolves the original file only after its
    // first frame has painted, so opening a large photo never blocks the tap or
    // the route transition.
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final result = await Navigator.of(context, rootNavigator: true)
        .push<ChatMediaEditorResult>(
          ExpandingSurfaceRoute<ChatMediaEditorResult>(
            origin: origin,
            animationsDisabled: reduceMotion,
            builder: (context, animation) => ChatMediaEditorView(
              asset: asset,
              repository: widget.repository,
            ),
          ),
        );

    if (!mounted || result == null) return;

    if (result.wasEdited) {
      Navigator.of(
        context,
      ).pop(AttachmentGalleryResult.prepared(result.editedFilePath));
    }
  }

  @override
  Widget build(BuildContext context) {
    final initialExtent =
        widget.config.initialExtent == AttachmentSheetExtent.expanded
        ? MediaGalleryTokens.expandedExtent
        : MediaGalleryTokens.compactExtent;

    return PopScope(
      canPop: !_menuMounted,

      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _menuMounted) unawaited(_closeAlbumMenu());
      },

      child: NotificationListener<DraggableScrollableNotification>(
        onNotification: (notification) {
          if (!_dismissing &&
              notification.extent <= MediaGalleryTokens.minExtent + .002) {
            _dismissSheet();
          }

          return false;
        },

        child: DraggableScrollableSheet(
          controller: _sheetController,

          // Let the modal route expose the area above the visible sheet to its

          // barrier. With the default `expand: true`, this widget's transparent

          // layout occupied the full route and swallowed outside taps.
          expand: false,

          initialChildSize: initialExtent,

          minChildSize: MediaGalleryTokens.minExtent,

          maxChildSize: MediaGalleryTokens.expandedExtent,

          snap: true,

          snapSizes: const [
            MediaGalleryTokens.compactExtent,

            MediaGalleryTokens.expandedExtent,
          ],

          shouldCloseOnMinExtent: true,

          builder: (context, scrollController) {
            _bindGalleryScrollController(scrollController);

            final widthProgress =
                ((MediaQuery.sizeOf(context).shortestSide - 320) / 152).clamp(
                  0.0,

                  1.0,
                );

            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 3 + (2 * widthProgress),
              ),

              child: ClipRRect(
                borderRadius: MediaGalleryTokens.sheetRadius,

                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),

                  child: Material(
                    color: Colors.transparent,

                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,

                          end: Alignment.bottomCenter,

                          colors: [
                            WrytteColors.surfaceRaised,

                            Color(0xFF07090C),
                          ],
                        ),

                        borderRadius: MediaGalleryTokens.sheetRadius,

                        border: Border(
                          top: BorderSide(
                            color: Colors.white.withValues(alpha: .09),

                            width: .8,
                          ),
                        ),
                      ),

                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: AnimatedSwitcher(
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 190),

                              switchInCurve: Curves.easeOutCubic,

                              switchOutCurve: Curves.easeInCubic,

                              child: KeyedSubtree(
                                key: ValueKey(_tab),

                                child: _buildContent(scrollController),
                              ),
                            ),
                          ),

                          PositionedDirectional(
                            top: 0,

                            start: 0,

                            end: 0,

                            child: AnimatedBuilder(
                              animation: Listenable.merge([
                                _sheetExpansionProgress,

                                _galleryScrollProgress,
                              ]),

                              builder: (context, _) =>
                                  Selector<
                                    AttachmentGalleryViewModel,

                                    _HeaderData
                                  >(
                                    selector: (_, model) => _HeaderData(
                                      albumName:
                                          _tab == ChatAttachmentTab.gallery
                                          ? model.selectedAlbum?.name ??
                                                'Recents'
                                          : _tab.label,

                                      menuOpen: _menuMounted,

                                      selectedCount: _selectionCount(model),
                                    ),

                                    builder: (context, data, _) =>
                                        AttachmentSheetHeader(
                                          albumName: data.albumName,

                                          menuOpen: data.menuOpen,

                                          selectedCount: data.selectedCount,

                                          expansionProgress:
                                              _sheetExpansionProgress.value,

                                          scrollProgress:
                                              _galleryScrollProgress.value,

                                          onClose: _dismissSheet,

                                          onAlbumPressed:
                                              _tab == ChatAttachmentTab.gallery
                                              ? _toggleAlbumMenu
                                              : null,

                                          showSearch:
                                              _tab == ChatAttachmentTab.location,

                                          onSearchPressed:
                                              _tab == ChatAttachmentTab.location
                                              ? () {}
                                              : null,

                                          onVerticalDragStart:
                                              _handleHeaderDragStart,

                                          onVerticalDragUpdate:
                                              _handleHeaderDragUpdate,

                                          onVerticalDragEnd:
                                              _handleHeaderDragEnd,

                                          onVerticalDragCancel:
                                              _handleHeaderDragCancel,
                                        ),
                                  ),
                            ),
                          ),

                          if (widget.config.purpose !=
                              AttachmentPurpose.profilePhoto)
                            PositionedDirectional(
                              start: 0,

                              end: 0,

                              bottom: 0,

                              child: Builder(
                                builder: (context) {
                                  final model = context
                                      .watch<AttachmentGalleryViewModel>();

                                  final count = _selectionCount(model);

                                  return AnimatedSwitcher(
                                    duration:
                                        MediaQuery.disableAnimationsOf(context)
                                        ? Duration.zero
                                        : const Duration(milliseconds: 180),

                                    child: count > 0
                                        ? ChatAttachmentSendBar(
                                            key: const ValueKey('send'),

                                            count: count,

                                            captionController:
                                                _tab ==
                                                    ChatAttachmentTab.gallery
                                                ? _captionController
                                                : null,

                                            onSend: _confirm,
                                          )
                                        : ChatAttachmentCategoryBar(
                                            key: const ValueKey('categories'),

                                            selected: _tab,

                                            onSelected: _selectTab,
                                          ),
                                  );
                                },
                              ),
                            ),

                          if (widget.config.purpose ==
                                  AttachmentPurpose.profilePhoto &&
                              widget.onRemovePhoto != null)
                            PositionedDirectional(
                              start: 0,
                              end: 0,
                              bottom: 0,
                              child: SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Center(
                                    child: GestureDetector(
                                      onTap: () async {
                                        _dismissSheet();
                                        await widget.onRemovePhoto!.call();
                                      },
                                      child: Container(
                                        width: 150,
                                        height: 40,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1C1C1E)
                                              .withValues(alpha: .70),
                                          borderRadius:
                                              BorderRadius.circular(22),
                                        ),
                                        child: const Text(
                                          'Remove photo',
                                          style: TextStyle(
                                            color: Color(0xFFFF4D4D),
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          if (_menuMounted &&
                              _tab == ChatAttachmentTab.gallery) ...[
                            Positioned.fill(
                              top: MediaGalleryTokens.headerHeight,

                              child: FadeTransition(
                                opacity: _menuOpacity,

                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,

                                  onTap: _closeAlbumMenu,

                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ),

                            PositionedDirectional(
                              top: MediaGalleryTokens.headerHeight + 4,

                              start: 18,

                              end: 18,

                              child: AnimatedBuilder(
                                animation: _menuController,

                                child:
                                    Selector<
                                      AttachmentGalleryViewModel,

                                      _AlbumData
                                    >(
                                      selector: (_, model) => _AlbumData(
                                        albums: model.albums,

                                        selectedAlbumId:
                                            model.selectedAlbum?.id,
                                      ),

                                      builder: (context, data, _) => AlbumMenu(
                                        albums: data.albums,

                                        selectedAlbumId: data.selectedAlbumId,

                                        repository: widget.repository,

                                        onSelected: _selectAlbum,
                                      ),
                                    ),

                                builder: (context, child) {
                                  final closing =
                                      _menuController.status ==
                                      AnimationStatus.reverse;

                                  final progress =
                                      (closing
                                              ? Curves.easeInOutCubic
                                              : Curves.easeOutCubic)
                                          .transform(_menuController.value);

                                  return Opacity(
                                    opacity: progress,

                                    child: ClipRect(
                                      child: Align(
                                        alignment: Alignment.topCenter,

                                        widthFactor: progress,

                                        heightFactor: progress,

                                        child: child,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
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

class _HeaderData {
  const _HeaderData({
    required this.albumName,

    required this.menuOpen,

    required this.selectedCount,
  });

  final String albumName;

  final bool menuOpen;

  final int selectedCount;

  @override
  bool operator ==(Object other) =>
      other is _HeaderData &&
      albumName == other.albumName &&
      menuOpen == other.menuOpen &&
      selectedCount == other.selectedCount;

  @override
  int get hashCode => Object.hash(albumName, menuOpen, selectedCount);
}

class _ContentData {
  const _ContentData({required this.access, required this.contentState});

  final MediaLibraryAccess access;

  final GalleryContentState contentState;

  @override
  bool operator ==(Object other) =>
      other is _ContentData &&
      access == other.access &&
      contentState == other.contentState;

  @override
  int get hashCode => Object.hash(access, contentState);
}

class _AlbumData {
  const _AlbumData({required this.albums, required this.selectedAlbumId});

  final List<MediaAlbum> albums;

  final String? selectedAlbumId;

  @override
  bool operator ==(Object other) =>
      other is _AlbumData &&
      identical(albums, other.albums) &&
      selectedAlbumId == other.selectedAlbumId;

  @override
  int get hashCode => Object.hash(identityHashCode(albums), selectedAlbumId);
}
