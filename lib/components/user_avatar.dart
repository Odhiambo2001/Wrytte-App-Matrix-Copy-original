import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

class UserAvatar extends StatefulWidget {
  final double size;
  final ImageProvider? image;
  final String? imageUrl;
  final String? localImagePath;
  final String? name;
  final VoidCallback? onTap;
  final String? heroTag;
  final String? cacheIdentity;
  final bool isDeleted;

  const UserAvatar({
    super.key,
    this.size = 40.0,
    this.image,
    this.imageUrl,
    this.localImagePath,
    this.name,
    this.onTap,
    this.heroTag,
    this.cacheIdentity,
    this.isDeleted = false,
  });

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  // ── App-wide resolved-image cache ───────────────────────────────────────
  // Once a CachedNetworkImage for a given URL has successfully resolved at
  // least once (this app session), we remember its ImageProvider here. Any
  // future build for the same URL — even in a brand new UserAvatar instance
  // after a parent rebuild — paints directly from this provider with zero
  // placeholder frame. This is what actually stops the flicker, because
  // CachedNetworkImage's `placeholder` builder still renders for one frame
  // on every widget rebuild while it asynchronously checks its disk cache,
  // even if the bytes are already on disk.
  static final Map<String, ImageProvider> _resolvedImageCache = {};

  // Tracks which raw localImagePath strings have been confirmed to exist on
  // disk, so we don't repeatedly hit File.existsSync() and so a transient
  // "file missing" check (e.g. mid-write) doesn't permanently blacklist a
  // path that becomes valid moments later.
  static final Set<String> _knownGoodLocalPaths = {};

  String? _backendToken;
  String? _lastGoodImageUrl;
  String? _lastGoodLocalImagePath;

  @override
  void initState() {
    super.initState();
    _rememberStableSources();
    _warmAuthToken();
  }

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheIdentity != widget.cacheIdentity) {
      _lastGoodImageUrl = null;
      _lastGoodLocalImagePath = null;
    }
    _rememberStableSources();
    if (oldWidget.imageUrl != widget.imageUrl) {
      _warmAuthToken();
    }
  }

  void _rememberStableSources() {
    final imageUrl = widget.imageUrl?.trim() ?? '';
    if (imageUrl.isNotEmpty) _lastGoodImageUrl = imageUrl;

    final localPath = widget.localImagePath?.trim() ?? '';
    if (localPath.isNotEmpty) {
      if (_knownGoodLocalPaths.contains(localPath)) {
        _lastGoodLocalImagePath = localPath;
      } else if (File(localPath).existsSync()) {
        _knownGoodLocalPaths.add(localPath);
        _lastGoodLocalImagePath = localPath;
      }
    }
  }

  void _warmAuthToken() {
    final cached = AuthService.instance.cachedBackendToken?.trim() ?? '';
    if (cached.isNotEmpty) {
      _backendToken = cached;
      return;
    }
    AuthService.instance
        .getValidBackendToken()
        .then((token) {
          final clean = token?.trim() ?? '';
          if (!mounted || clean.isEmpty || clean == _backendToken) return;
          setState(() => _backendToken = clean);
        })
        .catchError((error) {
          debugPrint('[UserAvatar] auth token warm skipped: $error');
        });
  }

  @override
  Widget build(BuildContext context) {
    Widget avatarWidget;

    if (widget.isDeleted) {
      return _wrapAvatar(_buildDeletedGhost());
    }

    final localFile = _localImageFile();

    final imageUrl = _effectiveImageUrl();
    final cachedProvider =
        imageUrl.isNotEmpty
            ? _resolvedImageCache[_providerCacheKey(imageUrl)]
            : null;

    if (widget.image != null) {
      avatarWidget = _buildFromImageProvider(widget.image!);
    } else if (localFile != null) {
      _lastGoodLocalImagePath = localFile.path;
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
            _knownGoodLocalPaths.remove(localFile.path);
            if (cachedProvider != null) {
              return _buildFromImageProvider(cachedProvider);
            }
            return imageUrl.isNotEmpty
                ? _buildNetworkOrPlaceholder(imageUrl)
                : _buildPlaceholder();
          },
        ),
      );
    } else if (cachedProvider != null) {
      // We've already successfully rendered this exact URL before in this
      // session — paint directly from the resolved provider. No
      // CachedNetworkImage, no placeholder frame, no flicker.
      avatarWidget = _buildFromImageProvider(cachedProvider);
    } else if (imageUrl.isNotEmpty) {
      avatarWidget = _buildNetworkOrPlaceholder(imageUrl);
    } else {
      avatarWidget = _buildPlaceholder();
    }

    return _wrapAvatar(avatarWidget);
  }

  Widget _wrapAvatar(Widget avatarWidget) {
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

  Widget _buildDeletedGhost() {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF2A6BD4),
      ),
      child: Icon(
        Icons.person_off_rounded,
        size: widget.size * 0.55,
        color: Colors.white,
      ),
    );
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
    final path =
        (widget.localImagePath?.trim().isNotEmpty == true
                ? widget.localImagePath
                : _lastGoodLocalImagePath)
            ?.trim() ??
        '';
    if (path.isEmpty) return null;
    if (_knownGoodLocalPaths.contains(path)) return File(path);
    final file = File(path);
    if (file.existsSync()) {
      _knownGoodLocalPaths.add(path);
      return file;
    }
    return null;
  }

  String _effectiveImageUrl() {
    final direct = widget.imageUrl?.trim() ?? '';
    if (direct.isNotEmpty) return direct;
    return _lastGoodImageUrl?.trim() ?? '';
  }

  Widget _buildNetworkOrPlaceholder(String rawUrl) {
    final url = _resolveImageUrl(rawUrl);
    if (url.isEmpty) return _buildPlaceholder();
    final providerKey = _providerCacheKey(rawUrl);
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        cacheKey: providerKey,
        imageBuilder: (context, imageProvider) {
          _lastGoodImageUrl = rawUrl;
          // Remember this provider so every future build (including in
          // other UserAvatar instances for the same URL — other screens,
          // conversation tiles, profile page, etc.) can skip straight to
          // painting it with zero placeholder frame.
          _resolvedImageCache[providerKey] = imageProvider;
          return Image(
            image: imageProvider,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
          );
        },
        httpHeaders: _authHeaders(
          _backendToken ?? AuthService.instance.cachedBackendToken,
          rawUrl: rawUrl,
        ),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholderFadeInDuration: Duration.zero,
        useOldImageOnUrlChange: true,
        placeholder: (context, url) => _buildPlaceholder(),
        errorWidget: (context, url, error) {
          debugPrint('[UserAvatar] image load failed url="$url" error=$error');
          return _buildPlaceholder();
        },
      ),
    );
  }

  String _providerCacheKey(String rawUrl) {
    final url = _resolveImageUrl(rawUrl);
    final identity = widget.cacheIdentity?.trim() ?? '';
    return identity.isEmpty ? url : '$identity|$url';
  }

  String _resolveImageUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
    if (url.startsWith('mxc://')) return _resolveMxcUrl(url);
    return url.startsWith('/') ? '${ApiService.baseUrl}$url' : url;
  }

  String _resolveMxcUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isScheme('mxc')) return '';
    final mediaId = uri.pathSegments.join('/');
    if (uri.host.isEmpty || mediaId.isEmpty) return '';
    final homeserver = Uri.tryParse(MatrixConfig.homeserver);
    if (homeserver == null || !homeserver.hasScheme) return '';
    return homeserver
        .resolve(
          '/_matrix/media/v3/download/'
          '${Uri.encodeComponent(uri.host)}/'
          '${Uri.encodeComponent(mediaId)}',
        )
        .toString();
  }

  Map<String, String>? _authHeaders(String? token, {required String rawUrl}) {
    if (rawUrl.trim().startsWith('mxc://')) {
      final matrixToken =
          MatrixClientService.instance.client.accessToken?.trim() ?? '';
      return matrixToken.isEmpty
          ? null
          : {'Authorization': 'Bearer $matrixToken'};
    }

    final clean = token?.trim() ?? '';
    if (clean.isEmpty) return null;
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
