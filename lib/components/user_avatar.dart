import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class UserAvatar extends StatefulWidget {
  final double size;
  final ImageProvider? image;
  final String? imageUrl;
  final String? localImagePath;
  final String? name;
  final VoidCallback? onTap;
  final String? heroTag;

  const UserAvatar({
    super.key,
    this.size = 40.0,
    this.image,
    this.imageUrl,
    this.localImagePath,
    this.name,
    this.onTap,
    this.heroTag,
  });

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  late Future<String?> _tokenFuture;

  @override
  void initState() {
    super.initState();
    _tokenFuture = AuthService.instance.getValidBackendToken();
  }

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _tokenFuture = AuthService.instance.getValidBackendToken();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget avatarWidget;

    final localFile = _localImageFile();

    if (widget.image != null) {
      avatarWidget = _buildFromImageProvider(widget.image!);
    } else if (localFile != null) {
      avatarWidget = ClipOval(
        child: Image.file(
          localFile,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            debugPrint(
              '[UserAvatar] local image load failed path="${localFile.path}" error=$error',
            );
            return _buildNetworkOrPlaceholder();
          },
        ),
      );
    } else if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty) {
      avatarWidget = _buildNetworkOrPlaceholder();
    } else {
      avatarWidget = _buildPlaceholder();
    }

    final wrapped = GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: avatarWidget,
      ),
    );

    return widget.heroTag != null
        ? Hero(tag: widget.heroTag!, child: wrapped)
        : wrapped;
  }

  Widget _buildFromImageProvider(ImageProvider provider) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        image: DecorationImage(image: provider, fit: BoxFit.cover),
      ),
    );
  }

  File? _localImageFile() {
    final path = widget.localImagePath?.trim() ?? '';
    if (path.isEmpty) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  Widget _buildNetworkOrPlaceholder() {
    final url = _resolveImageUrl(widget.imageUrl);
    if (url.isEmpty) return _buildPlaceholder();
    return FutureBuilder<String?>(
      future: _tokenFuture,
      builder: (context, snapshot) {
        return ClipOval(
          child: CachedNetworkImage(
            imageUrl: url,
            httpHeaders: _authHeaders(snapshot.data),
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            placeholder: (context, url) => _buildPlaceholder(),
            errorWidget: (context, url, error) {
              debugPrint(
                '[UserAvatar] image load failed url="$url" error=$error',
              );
              return _buildPlaceholder();
            },
          ),
        );
      },
    );
  }

  String _resolveImageUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
    if (url.startsWith('/')) return '${ApiService.baseUrl}$url';
    return url;
  }

  Map<String, String>? _authHeaders(String? token) {
    final clean = token?.trim() ?? '';
    if (clean.isEmpty) return null;
    final rawUrl = widget.imageUrl?.trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    final isWrytteImage =
        rawUrl.startsWith('/usrimg/') ||
        uri?.host.toLowerCase() == 'wryttedev.azurewebsites.net' ||
        uri?.host.toLowerCase() == 'wrytte.com';
    if (!isWrytteImage) return null;
    return {'Authorization': 'Bearer $clean'};
  }

  Widget _buildPlaceholder() {
    // Show initials if name is available, otherwise icon
    final initials = _getInitials(widget.name);

    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF0F2A44),
      ),
      child: Center(
        child:
            initials != null
                ? Text(
                  initials,
                  style: TextStyle(
                    color: const Color(0xFF4DA3FF),
                    fontSize: widget.size * 0.36,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                )
                : Icon(
                  Icons.person,
                  size: widget.size * 0.5,
                  color: const Color(0xFF4DA3FF),
                ),
      ),
    );
  }

  /// Returns up to 2 initials from the name, or null if name is empty.
  String? _getInitials(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}
