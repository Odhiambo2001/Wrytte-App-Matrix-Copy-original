import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/view_models/attachment_gallery_view_model.dart';
import 'package:wrytte/ui/media/widgets/media_selection_badge.dart';
import 'package:wrytte/ui/media/widgets/media_thumbnail_image.dart';

class MediaThumbnailTile extends StatelessWidget {
  const MediaThumbnailTile({
    super.key,
    required this.asset,
    required this.repository,
    required this.pixelSize,
    this.showSelectionIndicator = true,
    this.onPressed,
  });

  final MediaAsset asset;
  final MediaLibraryRepository repository;
  final int pixelSize;
  final bool showSelectionIndicator;
  final VoidCallback? onPressed;

  void _toggleSelection(BuildContext context) {
    unawaited(HapticFeedback.selectionClick());

    context
        .read<AttachmentGalleryViewModel>()
        .toggleSelection(asset);
  }

  @override
  Widget build(BuildContext context) {
    final deferred =
        Scrollable.recommendDeferredLoadingForContext(context);

    return Selector<AttachmentGalleryViewModel, int>(
      selector: (_, model) => model.selectionIndex(asset.id),
      builder: (context, selectionIndex, _) {
        final selected = selectionIndex > 0;

        return Semantics(
          button: true,
          label: asset.kind == MediaKind.video
              ? onPressed == null
                  ? 'Select video'
                  : 'Open video'
              : onPressed == null
                  ? 'Select photo'
                  : 'Open photo',
          child: Material(
            color: WrytteColors.surfaceRaised,
            child: InkWell(
              onTap: onPressed ?? () => _toggleSelection(context),
              splashFactory: NoSplash.splashFactory,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: MediaAssetThumbnail(
                      asset: asset,
                      repository: repository,
                      pixelSize: pixelSize,
                    ),
                  ),

                  if (asset.kind == MediaKind.video && !deferred)
                    PositionedDirectional(
                      start: 7,
                      bottom: 6,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _formatDuration(asset.duration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (showSelectionIndicator)
                    PositionedDirectional(
                      // 40px interaction box, but the visible 24px circle
                      // lands exactly at top/right = 6px.
                      top: -2,
                      end: -2,
                      child: Semantics(
                        button: true,
                        selected: selected,
                        label: selected
                            ? 'Deselect ${_mediaLabel}, selected as number '
                                '$selectionIndex'
                            : 'Select ${_mediaLabel}',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _toggleSelection(context),
                          child: SizedBox.square(
                            dimension: 40,
                            child: Center(
                              child: ExcludeSemantics(
                                child: MediaSelectionBadge(
                                  index: selectionIndex,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String get _mediaLabel =>
      asset.kind == MediaKind.video ? 'video' : 'photo';

  String _formatDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds =
        value.inSeconds.remainder(60).toString().padLeft(2, '0');

    return '$minutes:$seconds';
  }
}