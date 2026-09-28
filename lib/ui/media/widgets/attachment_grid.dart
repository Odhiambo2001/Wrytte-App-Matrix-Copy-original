import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/view_models/attachment_gallery_view_model.dart';
import 'package:wrytte/ui/media/widgets/camera_placeholder_tile.dart';
import 'package:wrytte/ui/media/widgets/media_gallery_tokens.dart';
import 'package:wrytte/ui/media/widgets/media_thumbnail_tile.dart';

typedef AttachmentAssetPressed =
    Future<void> Function(MediaAsset asset, ExpandingSurfaceOrigin origin);

class AttachmentGrid extends StatefulWidget {
  const AttachmentGrid({
    super.key,
    required this.scrollController,
    required this.repository,
    required this.showCameraPlaceholder,
    required this.showSelectionIndicators,
    required this.expansionProgress,
    this.cameraPreview,
    this.initialLoading = false,
    this.onCameraPressed,
    this.onAssetPressed,
  });

  final ScrollController scrollController;
  final MediaLibraryRepository repository;
  final bool showCameraPlaceholder;
  final bool showSelectionIndicators;
  final ValueListenable<double> expansionProgress;
  final Widget? cameraPreview;
  final bool initialLoading;
  final ValueChanged<ExpandingSurfaceOrigin>? onCameraPressed;
  final AttachmentAssetPressed? onAssetPressed;

  @override
  State<AttachmentGrid> createState() => _AttachmentGridState();
}

class _AttachmentGridState extends State<AttachmentGrid> {
  final _cameraTileKey = GlobalKey();
  int _lastWarmedLength = 0;
  String? _firstAssetId;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(AttachmentGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.scrollController.hasClients) return;
    final position = widget.scrollController.position;
    if (position.extentAfter < position.viewportDimension * 1.4) {
      unawaited(context.read<AttachmentGalleryViewModel>().loadNextPage());
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = context.select<AttachmentGalleryViewModel, _GridData>(
      (model) => _GridData(
        assets: model.assets,
        pagingState: model.pagingState,
        newAssetCount: model.newAssetCount,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            (constraints.maxWidth / MediaGalleryTokens.targetTileExtent)
                .floor()
                .clamp(3, 6);
        final widthProgress =
            ((MediaQuery.sizeOf(context).shortestSide - 320) / 152)
                .clamp(0.0, 1.0)
                .toDouble();
        final headerHeight = 60 + (6 * widthProgress);
        final tileWidth =
            (constraints.maxWidth -
                (columns - 1) * MediaGalleryTokens.gridGap) /
            columns;
        final tileHeight = tileWidth * 1.08;
        final pixelSize = (tileWidth * MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(128, 1024);
        _warmVisibleWindow(data.assets, pixelSize);
        _preserveScrollAnchor(data, columns, tileHeight);

        final showPaging =
            !widget.initialLoading &&
                data.pagingState == GalleryPagingState.loading ||
            !widget.initialLoading &&
                data.pagingState == GalleryPagingState.failed;
        final visibleRows =
            ((constraints.maxHeight - headerHeight) /
                    (tileHeight + MediaGalleryTokens.gridGap))
                .ceil()
                .clamp(3, 8);
        final displayedAssetCount = widget.initialLoading
            ? (columns * visibleRows) - 2
            : data.assets.length;
        final featuredAssetCount = widget.showCameraPlaceholder
            ? ((columns - 1) * 2).clamp(0, displayedAssetCount)
            : 0;
        final remainingCount = displayedAssetCount - featuredAssetCount;

        Widget assetTile(int assetIndex) {
          if (assetIndex >= data.assets.length) {
            return const ColoredBox(color: WrytteColors.surfaceRaised);
          }
          final asset = data.assets[assetIndex];
          return Builder(
            key: ValueKey(asset.id),
            builder: (tileContext) => MediaThumbnailTile(
              asset: asset,
              repository: widget.repository,
              pixelSize: pixelSize,
              showSelectionIndicator: widget.showSelectionIndicators,
              onPressed: widget.onAssetPressed == null
                  ? null
                  : () {
                      final origin = ExpandingSurfaceOrigin.fromContext(
                        tileContext,
                        borderRadius: BorderRadius.circular(2),
                      );
                      if (origin != null) {
                        unawaited(widget.onAssetPressed!(asset, origin));
                      }
                    },
            ),
          );
        }

        return CustomScrollView(
          controller: widget.scrollController,
          scrollCacheExtent: const ScrollCacheExtent.viewport(1.75),
          slivers: [
            SliverToBoxAdapter(
              child: ValueListenableBuilder<double>(
                valueListenable: widget.expansionProgress,
                builder: (context, expansion, _) => SizedBox(
                  height:
                      headerHeight * (1 - expansion.clamp(0.0, 1.0).toDouble()),
                ),
              ),
            ),
            if (widget.showCameraPlaceholder)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: (tileHeight * 2) + MediaGalleryTokens.gridGap,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: tileWidth,
                        child: CameraPlaceholderTile(
                          key: _cameraTileKey,
                          preview: widget.cameraPreview,
                          onPressed: widget.onCameraPressed == null
                              ? null
                              : _openCamera,
                        ),
                      ),
                      const SizedBox(width: MediaGalleryTokens.gridGap),
                      Expanded(
                        child: Column(
                          children: [
                            for (var row = 0; row < 2; row++) ...[
                              Expanded(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (
                                      var column = 0;
                                      column < columns - 1;
                                      column++
                                    ) ...[
                                      if (column > 0)
                                        const SizedBox(
                                          width: MediaGalleryTokens.gridGap,
                                        ),
                                      Expanded(
                                        child:
                                            row * (columns - 1) + column <
                                                featuredAssetCount
                                            ? assetTile(
                                                row * (columns - 1) + column,
                                              )
                                            : const ColoredBox(
                                                color: Color(0xFF0B0D10),
                                              ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (row == 0)
                                const SizedBox(
                                  height: MediaGalleryTokens.gridGap,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.showCameraPlaceholder)
              const SliverToBoxAdapter(
                child: SizedBox(height: MediaGalleryTokens.gridGap),
              ),
            if (remainingCount > 0)
              SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: MediaGalleryTokens.gridGap,
                  crossAxisSpacing: MediaGalleryTokens.gridGap,
                  mainAxisExtent: tileHeight,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, index) => assetTile(index + featuredAssetCount),
                  childCount: remainingCount,
                ),
              ),
            if (showPaging)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: tileHeight,
                  child: data.pagingState == GalleryPagingState.failed
                      ? Center(
                          child: IconButton(
                            tooltip: 'Retry loading more photos',
                            onPressed: () => context
                                .read<AttachmentGalleryViewModel>()
                                .loadNextPage(),
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        )
                      : const Center(
                          child: SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + 88,
              ),
            ),
          ],
        );
      },
    );
  }

  void _openCamera() {
    final origin = ExpandingSurfaceOrigin.fromKey(
      _cameraTileKey,
      borderRadius: BorderRadius.circular(2),
    );
    if (origin != null) widget.onCameraPressed?.call(origin);
  }

  void _warmVisibleWindow(List<MediaAsset> assets, int pixelSize) {
    if (assets.length == _lastWarmedLength || assets.isEmpty) return;
    _lastWarmedLength = assets.length;
    final start = (assets.length - 32).clamp(0, assets.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        widget.repository.warmThumbnails(
          assets.skip(start).map((asset) => asset.id),
          width: pixelSize,
          height: pixelSize,
        ),
      );
    });
  }

  void _preserveScrollAnchor(_GridData data, int columns, double tileExtent) {
    final nextFirstId = data.assets.firstOrNull?.id;
    final previousFirstId = _firstAssetId;
    _firstAssetId = nextFirstId;
    if (previousFirstId == null ||
        previousFirstId == nextFirstId ||
        data.newAssetCount == 0) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.scrollController.hasClients) return;
      final position = widget.scrollController.position;
      if (position.pixels <= 1) return;
      final insertedRows = (data.newAssetCount / columns).ceil();
      final target =
          (position.pixels +
                  insertedRows * (tileExtent + MediaGalleryTokens.gridGap))
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      widget.scrollController.jumpTo(target);
    });
  }
}

class _GridData {
  const _GridData({
    required this.assets,
    required this.pagingState,
    required this.newAssetCount,
  });

  final List<MediaAsset> assets;
  final GalleryPagingState pagingState;
  final int newAssetCount;

  @override
  bool operator ==(Object other) =>
      other is _GridData &&
      identical(assets, other.assets) &&
      pagingState == other.pagingState &&
      newAssetCount == other.newAssetCount;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(assets), pagingState, newAssetCount);
}
