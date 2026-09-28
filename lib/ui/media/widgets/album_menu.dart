import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/media_album.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/widgets/album_menu_item.dart';
import 'package:wrytte/ui/media/widgets/media_gallery_tokens.dart';

class AlbumMenu extends StatelessWidget {
  const AlbumMenu({
    super.key,
    required this.albums,
    required this.selectedAlbumId,
    required this.repository,
    required this.onSelected,
  });

  final List<MediaAlbum> albums;
  final String? selectedAlbumId;
  final MediaLibraryRepository repository;
  final ValueChanged<MediaAlbum> onSelected;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaGalleryTokens.menuMaxWidth.clamp(0, width - 36),
          maxHeight: MediaGalleryTokens.menuMaxHeight.clamp(
            0,
            MediaQuery.sizeOf(context).height * .54,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    WrytteColors.surfaceRaised.withValues(alpha: .82),
                    const Color(0xFF0B0D11).withValues(alpha: .78),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .32),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  shrinkWrap: true,
                  itemCount: albums.length,
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    return AlbumMenuItem(
                      key: ValueKey(album.id),
                      album: album,
                      selected: album.id == selectedAlbumId,
                      repository: repository,
                      onPressed: () => onSelected(album),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
