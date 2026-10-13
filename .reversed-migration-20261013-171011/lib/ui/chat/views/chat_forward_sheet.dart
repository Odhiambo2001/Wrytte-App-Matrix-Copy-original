import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:wrytte/ui/chat/models/chat_forward_target.dart';
import 'package:wrytte/ui/chat/widgets/forwarding/chat_forward_contact_row.dart';
import 'package:wrytte/ui/chat/widgets/forwarding/chat_forward_header.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/media/widgets/chat_attachment_send_bar.dart';
import 'package:wrytte/ui/media/widgets/media_gallery_tokens.dart';

const List<ChatForwardTarget> _demoForwardTargets = [
  ChatForwardTarget(
    id: 'alex-morgan',
    title: 'Alex Morgan',
    subtitle: '+1 613 555 0142',
  ),
  ChatForwardTarget(
    id: 'maya-chen',
    title: 'Maya Chen',
    subtitle: '+1 613 555 0194',
  ),
  ChatForwardTarget(
    id: 'daniel-kim',
    title: 'Daniel Kim',
    subtitle: '+1 343 555 0128',
  ),
  ChatForwardTarget(
    id: 'sophia-williams',
    title: 'Sophia Williams',
    subtitle: '+1 613 555 0117',
  ),
  ChatForwardTarget(
    id: 'noah-brown',
    title: 'Noah Brown',
    subtitle: '+1 343 555 0171',
  ),
  ChatForwardTarget(
    id: 'olivia-martin',
    title: 'Olivia Martin',
    subtitle: '+1 613 555 0168',
  ),
  ChatForwardTarget(
    id: 'liam-wilson',
    title: 'Liam Wilson',
    subtitle: '+1 613 555 0103',
  ),
  ChatForwardTarget(
    id: 'emma-davis',
    title: 'Emma Davis',
    subtitle: '+1 343 555 0159',
  ),
  ChatForwardTarget(
    id: 'ethan-taylor',
    title: 'Ethan Taylor',
    subtitle: '+1 613 555 0131',
  ),
  ChatForwardTarget(
    id: 'ava-johnson',
    title: 'Ava Johnson',
    subtitle: '+1 613 555 0186',
  ),
  ChatForwardTarget(
    id: 'lucas-anderson',
    title: 'Lucas Anderson',
    subtitle: '+1 343 555 0148',
  ),
  ChatForwardTarget(
    id: 'mia-thompson',
    title: 'Mia Thompson',
    subtitle: '+1 613 555 0125',
  ),
  ChatForwardTarget(
    id: 'james-robinson',
    title: 'James Robinson',
    subtitle: '+1 343 555 0164',
  ),
  ChatForwardTarget(
    id: 'zoe-clark',
    title: 'Zoe Clark',
    subtitle: '+1 613 555 0178',
  ),
];

Future<List<ChatForwardTarget>?> showWrytteChatForwardSheet(
  BuildContext context, {
  required String previewText,
  List<ChatForwardTarget> targets = _demoForwardTargets,
}) {
  // Keep this route configuration in lock-step with the normal attachment
  // sheet so opening and closing have the same bottom-sheet motion.
  final disableAnimations = MediaQuery.disableAnimationsOf(context);

  return showModalBottomSheet<List<ChatForwardTarget>>(
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
    builder: (_) => _ChatForwardSheet(
      previewText: previewText,
      targets: targets,
    ),
  );
}

class _ChatForwardSheet extends StatefulWidget {
  const _ChatForwardSheet({
    required this.previewText,
    required this.targets,
  });

  final String previewText;
  final List<ChatForwardTarget> targets;

  @override
  State<_ChatForwardSheet> createState() => _ChatForwardSheetState();
}

class _ChatForwardSheetState extends State<_ChatForwardSheet> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final Set<String> _selectedIds = <String>{};

  // Same two signals the normal attachment header uses to decide when its
  // compact solid background should transition into the full-screen glass one.
  final ValueNotifier<double> _sheetExpansionProgress = ValueNotifier<double>(0);
  final ValueNotifier<double> _contentScrollProgress = ValueNotifier<double>(0);
  ScrollController? _contentScrollController;

  String _query = '';
  bool _searchActive = false;
  bool _dismissing = false;
  bool _headerDragWasDownward = false;

  List<ChatForwardTarget> get _filteredTargets {
    final query = _query.trim().toLowerCase();

    if (query.isEmpty) {
      return widget.targets;
    }

    return widget.targets
        .where(
          (target) =>
              target.title.toLowerCase().contains(query) ||
              target.subtitle.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  List<ChatForwardTarget> get _selectedTargets => widget.targets
      .where((target) => _selectedIds.contains(target.id))
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_syncSheetExpansion);
  }

  @override
  void dispose() {
    _contentScrollController?.removeListener(_syncContentScroll);
    _sheetController.removeListener(_syncSheetExpansion);
    _sheetExpansionProgress.dispose();
    _contentScrollProgress.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  void _bindContentScrollController(ScrollController controller) {
    if (identical(_contentScrollController, controller)) return;

    _contentScrollController?.removeListener(_syncContentScroll);
    _contentScrollController = controller;
    controller.addListener(_syncContentScroll);
    _syncContentScroll();
  }

  void _syncContentScroll() {
    final controller = _contentScrollController;
    if (controller == null || !controller.hasClients) return;

    final progress = (controller.offset / 28).clamp(0.0, 1.0).toDouble();
    if ((_contentScrollProgress.value - progress).abs() > .001) {
      _contentScrollProgress.value = progress;
    }
  }

  void _syncSheetExpansion() {
    if (!_sheetController.isAttached) return;

    final progress =
        ((_sheetController.size - MediaGalleryTokens.compactExtent) /
                (MediaGalleryTokens.expandedExtent -
                    MediaGalleryTokens.compactExtent))
            .clamp(0.0, 1.0)
            .toDouble();

    if ((_sheetExpansionProgress.value - progress).abs() > .001) {
      _sheetExpansionProgress.value = progress;
    }
  }

  void _dismissSheet() {
    if (!mounted || _dismissing) return;

    _dismissing = true;
    _searchFocusNode.unfocus();
    Navigator.of(context).pop();
  }

  Future<void> _openSearch() async {
    if (_searchActive || !mounted) return;

    // First put the search field into the tree WITHOUT focusing it. Focusing a
    // TextField while DraggableScrollableSheet is still changing extent can ask
    // Flutter to perform competing layouts in the same frame.
    setState(() => _searchActive = true);
    await WidgetsBinding.instance.endOfFrame;

    if (!mounted || !_searchActive) return;

    // Finish the sheet resize before the IME is allowed to enter.
    if (_sheetController.isAttached &&
        _sheetController.size < MediaGalleryTokens.expandedExtent - .02) {
      await _sheetController.animateTo(
        MediaGalleryTokens.expandedExtent,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 230),
        curve: Curves.easeOutCubic,
      );
    }

    if (!mounted || !_searchActive) return;

    // Wait for the settled expanded layout, then focus outside that layout pass.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(Duration.zero);

    if (!mounted || !_searchActive) return;
    _searchFocusNode.requestFocus();
  }

  void _closeSearch() {
    if (!_searchActive) return;

    _searchFocusNode.unfocus();
    _searchController.clear();

    setState(() {
      _query = '';
      _searchActive = false;
    });
  }

  void _clearSearch() {
    if (_searchController.text.isEmpty) return;

    _searchController.clear();
    setState(() => _query = '');
    _searchFocusNode.requestFocus();
  }

  void _toggleTarget(ChatForwardTarget target) {
    setState(() {
      if (!_selectedIds.remove(target.id)) {
        _selectedIds.add(target.id);
      }
    });
  }

  void _confirmForward() {
    final selectedTargets = _selectedTargets;
    if (selectedTargets.isEmpty) return;

    _searchFocusNode.unfocus();
    Navigator.of(context).pop(selectedTargets);
  }

  void _handleHeaderDragStart(DragStartDetails details) {
    _headerDragWasDownward = false;
  }

  void _handleHeaderDragUpdate(DragUpdateDetails details) {
    if (!_sheetController.isAttached || _searchFocusNode.hasFocus) return;

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
    if (!_sheetController.isAttached ||
        _dismissing ||
        _searchFocusNode.hasFocus) {
      return;
    }

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

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return PopScope(
      canPop: !_searchActive,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _searchActive) {
          _closeSearch();
        }
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
          expand: false,
          initialChildSize: MediaGalleryTokens.compactExtent,
          minChildSize: MediaGalleryTokens.minExtent,
          maxChildSize: MediaGalleryTokens.expandedExtent,
          snap: true,
          snapSizes: const [
            MediaGalleryTokens.compactExtent,
            MediaGalleryTokens.expandedExtent,
          ],
          shouldCloseOnMinExtent: true,
          builder: (context, scrollController) {
            _bindContentScrollController(scrollController);

            final widthProgress =
                ((MediaQuery.sizeOf(context).shortestSide - 320) / 152)
                    .clamp(0.0, 1.0)
                    .toDouble();

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
                            child: _ForwardContactsBody(
                              scrollController: scrollController,
                              previewText: widget.previewText,
                              targets: _filteredTargets,
                              selectedIds: _selectedIds,
                              queryActive: _query.trim().isNotEmpty,
                              onToggle: _toggleTarget,
                            ),
                          ),

                          PositionedDirectional(
                            top: 0,
                            start: 0,
                            end: 0,
                            child: AnimatedBuilder(
                              animation: Listenable.merge([
                                _sheetExpansionProgress,
                                _contentScrollProgress,
                              ]),
                              builder: (context, _) => ChatForwardHeader(
                                selectedCount: _selectedIds.length,
                                searchActive: _searchActive,
                                searchQuery: _query,
                                searchController: _searchController,
                                searchFocusNode: _searchFocusNode,
                                expansionProgress:
                                    _sheetExpansionProgress.value,
                                scrollProgress: _contentScrollProgress.value,
                                onClose: _dismissSheet,
                                onSearchPressed: () {
                                  unawaited(_openSearch());
                                },
                                onSearchClosed: _closeSearch,
                                onSearchChanged: (value) {
                                  setState(() => _query = value);
                                },
                                onSearchCleared: _clearSearch,
                                onVerticalDragStart: _handleHeaderDragStart,
                                onVerticalDragUpdate: _handleHeaderDragUpdate,
                                onVerticalDragEnd: _handleHeaderDragEnd,
                                onVerticalDragCancel: _handleHeaderDragCancel,
                              ),
                            ),
                          ),

                          // Use the exact attachment send bar. With no caption
                          // controller it renders only the clean blue circular
                          // send control used by the normal attachment picker.
                          PositionedDirectional(
                            start: 0,
                            end: 0,
                            bottom: 0,
                            child: AnimatedSwitcher(
                              duration: reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 180),
                              child: _selectedIds.isEmpty
                                  ? const SizedBox.shrink(
                                      key: ValueKey<String>(
                                        'forward-send-hidden',
                                      ),
                                    )
                                  : ChatAttachmentSendBar(
                                      key: const ValueKey<String>(
                                        'forward-send',
                                      ),
                                      count: _selectedIds.length,
                                      onSend: _confirmForward,
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
          },
        ),
      ),
    );
  }
}

class _ForwardContactsBody extends StatelessWidget {
  const _ForwardContactsBody({
    required this.scrollController,
    required this.previewText,
    required this.targets,
    required this.selectedIds,
    required this.queryActive,
    required this.onToggle,
  });

  final ScrollController scrollController;
  final String previewText;
  final List<ChatForwardTarget> targets;
  final Set<String> selectedIds;
  final bool queryActive;
  final ValueChanged<ChatForwardTarget> onToggle;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = (width * .045).clamp(16.0, 20.0).toDouble();
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.20,
      child: CustomScrollView(
        controller: scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              78,
              horizontalPadding,
              0,
            ),
            sliver: SliverList.list(
              children: [
                _ForwardMessagePreview(text: previewText),
                const SizedBox(height: 22),
                Padding(
  padding: const EdgeInsetsDirectional.only(
    start: 5,
    end: 8,
  ),
  child: Row(
    children: [
      Text(
        queryActive ? 'SEARCH RESULTS' : 'CONTACTS',
        style: const TextStyle(
          color: WrytteColors.textMuted,
          fontFamily: WrytteTypography.primaryFontFamily,
          fontSize: 10.5,
          height: 1,
          fontWeight: FontWeight.w600,
          letterSpacing: .85,
        ),
      ),

      const Spacer(),

      SizedBox(
        width: 25,
        child: Center(
          child: Text(
            '${targets.length}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: WrytteColors.textMuted.withValues(
                alpha: .72,
              ),
              fontFamily: WrytteTypography.primaryFontFamily,
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    ],
  ),
),
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (targets.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  52,
                  horizontalPadding,
                  0,
                ),
                child: const _ForwardEmptyState(),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final target = targets[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: ChatForwardContactRow(
                        key: ValueKey<String>(target.id),
                        target: target,
                        selected: selectedIds.contains(target.id),
                        onTap: () => onToggle(target),
                      ),
                    );
                  },
                  childCount: targets.length,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: 112 + bottomInset),
          ),
        ],
      ),
    );
  }
}

class _ForwardMessagePreview extends StatelessWidget {
  const _ForwardMessagePreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cleanText = text.trim().isEmpty ? 'Message' : text.trim();

    // Keep the preview container, but do not add a forwarding icon/avatar. The
    // content itself is enough and leaves more room for video/file labels.
    return WrytteGlassSurface(
      borderRadius: BorderRadius.circular(19),
      blur: 22,
      color: WrytteColors.surfaceRaised.withValues(alpha: .56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'FORWARDING',
              style: TextStyle(
                color: WrytteColors.textMuted,
                fontFamily: WrytteTypography.primaryFontFamily,
                fontSize: 10.5,
                height: 1,
                letterSpacing: .7,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              cleanText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: WrytteColors.textPrimary,
                fontFamily: WrytteTypography.primaryFontFamily,
                fontSize: 14.5,
                height: 1.24,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForwardEmptyState extends StatelessWidget {
  const _ForwardEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.person_search_rounded,
            size: 31,
            color: WrytteColors.textMuted.withValues(alpha: .80),
          ),
          const SizedBox(height: 12),
          const Text(
            'No contacts found',
            style: TextStyle(
              color: WrytteColors.textPrimary,
              fontFamily: WrytteTypography.primaryFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Try another name or phone number.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: WrytteColors.textMuted,
              fontFamily: WrytteTypography.primaryFontFamily,
              fontSize: 12.5,
              height: 1.25,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
