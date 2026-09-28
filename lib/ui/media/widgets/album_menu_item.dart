import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/media_album.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/widgets/media_thumbnail_image.dart';

class AlbumMenuItem extends StatelessWidget {
  const AlbumMenuItem({
    super.key,
    required this.album,
    required this.selected,
    required this.repository,
    required this.onPressed,
  });

  final MediaAlbum album;
  final bool selected;
  final MediaLibraryRepository repository;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final coverId = album.coverAssetId;
    return Semantics(
      button: true,
      selected: selected,
      label: '${album.name}, ${album.assetCount} items',
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox.square(
                    dimension: 43,
                    child: coverId == null
                        ? const ColoredBox(color: WrytteColors.surfaceRaised)
                        : MediaThumbnailImage(
                            assetId: coverId,
                            repository: repository,
                            pixelSize: 128,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: WrytteColors.textPrimary,
                          fontSize: 15,
                          height: 1.08,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${album.assetCount} ${album.assetCount == 1 ? 'item' : 'items'}',
                        style: const TextStyle(
                          color: WrytteColors.textSecondary,
                          fontSize: 12,
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.check_rounded,
                    color: WrytteColors.primary,
                    size: 21,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
