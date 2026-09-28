import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/media_library_access.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class GalleryStateView extends StatelessWidget {
  const GalleryStateView({
    super.key,
    required this.access,
    required this.isLoading,
    required this.failed,
    required this.onRetry,
    required this.onOpenSettings,
    required this.onManageLimited,
  });

  final MediaLibraryAccess access;
  final bool isLoading;
  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;
  final VoidCallback onManageLimited;

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const _SkeletonGrid();
    final denied = !access.canRead;
    final title = denied
        ? 'Photo access needed'
        : failed
        ? 'Photos could not be loaded'
        : 'No photos here yet';
    final message = denied
        ? 'Allow Wrytte to show photos and videos from this device.'
        : failed
        ? 'Check access and try again.'
        : access == MediaLibraryAccess.limited
        ? 'Choose more photos to make them available here.'
        : 'New photos will appear here automatically.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              denied ? Icons.photo_library_outlined : Icons.photo_outlined,
              color: WrytteColors.textMuted,
              size: 42,
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WrytteColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: WrytteColors.textSecondary),
            ),
            const SizedBox(height: 18),
            TextButton(
              onPressed: denied
                  ? onOpenSettings
                  : access == MediaLibraryAccess.limited
                  ? onManageLimited
                  : onRetry,
              child: Text(denied ? 'Open settings' : 'Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: 12,
      itemBuilder: (_, index) =>
          const ColoredBox(color: WrytteColors.surfaceRaised),
    );
  }
}
