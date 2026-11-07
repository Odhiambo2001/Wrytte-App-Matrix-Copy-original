import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

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
  final bool suppressAvatar;

  static void clearMemoryCache() => _UserAvatarState.clearMemoryCache();

  static Future<void> evictCachedUrl(String? rawUrl) =>
      _UserAvatarState.evictCachedUrl(rawUrl);

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
    this.suppressAvatar = false,
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
  static final Set<String> _loggedPaintKeys = {};
  static final Set<String> _loggedLoadKeys = {};

  // Tracks which raw localImagePath strings have been confirmed to exist on
  // disk, so we don't repeatedly hit File.existsSync() and so a transient
  // "file missing" check (e.g. mid-write) doesn't permanently blacklist a
  // path that becomes valid moments later.
  static final Set<String> _knownGoodLocalPaths = {};

  /// Clears account-scoped avatar state during logout. Image providers can
  /// otherwise retain references after Flutter's global image cache is wiped.
  static void clearMemoryCache() {
    _resolvedImageCache.clear();
    _loggedPaintKeys.clear();
    _loggedLoadKeys.clear();
    _knownGoodLocalPaths.clear();
  }

  /// Removes every app and CachedNetworkImage cache entry for this avatar URL,
  /// including entries keyed by a surface-specific cache identity.
  static Future<void> evictCachedUrl(String? rawUrl) async {
    final url = _resolveImageUrl(rawUrl);
    if (url.isEmpty) return;
    final baseUrl = _stripVersion(url);
    final matchingKeys = _resolvedImageCache.keys.where((key) {
      final cachedUrl = key.contains('|') ? key.split('|').last : key;
      return _stripVersion(cachedUrl) == baseUrl;
    }).toList();

    for (final key in matchingKeys) {
      final provider = _resolvedImageCache.remove(key);
      _loggedPaintKeys.remove(key);
      _loggedLoadKeys.remove(key);
      if (provider != null) await provider.evict();
      final cachedUrl = key.contains('|') ? key.split('|').last : key;
      try {
        await CachedNetworkImage.evictFromCache(cachedUrl, cacheKey: key);
      } catch (error) {
        debugPrint('[UserAvatar] cache eviction skipped: $error');
      }
    }

    try {
      await CachedNetworkImage.evictFromCache(url);
      if (baseUrl != url) await CachedNetworkImage.evictFromCache(baseUrl);
    } catch (error) {
      debugPrint('[UserAvatar] cache eviction skipped: $error');
    }
  }

  String? _backendToken;
  String? _lastGoodImageUrl;
  String? _lastGoodLocalImagePath;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    AvatarPreloadService.cacheRevision.addListener(_onAvatarCacheChanged);
    _rememberStableSources();
    _warmAuthToken();
    unawaited(_loadPersistentAvatar());
  }

  void _onAvatarCacheChanged() {
    if (!mounted) return;
    unawaited(_loadPersistentAvatar());
  }

  @override
  void dispose() {
    AvatarPreloadService.cacheRevision.removeListener(_onAvatarCacheChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);

    _loadGeneration++;

    if (widget.suppressAvatar) {
      _lastGoodImageUrl = null;
      _lastGoodLocalImagePath = null;
    }

    final identityChanged = oldWidget.cacheIdentity != widget.cacheIdentity;
    final oldImageUrl = oldWidget.imageUrl?.trim() ?? '';
    final newImageUrl = widget.imageUrl?.trim() ?? '';
    final oldLocalPath = oldWidget.localImagePath?.trim() ?? '';
    final newLocalPath = widget.localImagePath?.trim() ?? '';

    // Keep the last good source during ordinary rebuilds, but an explicit
    // transition to an empty source means the profile owner removed the
    // avatar. Do not let _effectiveImageUrl/_localImageFile resurrect it.
    if (identityChanged) {
      _lastGoodImageUrl = null;
    }
    if (identityChanged) {
      _lastGoodLocalImagePath = null;
    }
    _rememberStableSources();
    unawaited(_loadPersistentAvatar());
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

    if (_lastGoodLocalImagePath == null && imageUrl.isNotEmpty) {
      final cachedPath = AvatarPreloadService.localPathSync(imageUrl);
      if (cachedPath != null) {
        _knownGoodLocalPaths.add(cachedPath);
        _lastGoodLocalImagePath = cachedPath;
      }
    }
  }

  void _warmAuthToken() {
    final rawUrl = widget.imageUrl?.trim() ?? '';
    final resolved = _resolveImageUrl(rawUrl);
    final host = Uri.tryParse(resolved)?.host.toLowerCase() ?? '';
    final needsBackendToken =
        rawUrl.startsWith('/usrimg/') ||
        ApiService.isBackendHost(host) ||
        host == 'wrytte.com';
    if (!needsBackendToken) return;
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

  Future<void> _loadPersistentAvatar() async {
    final rawUrl = widget.imageUrl?.trim() ?? '';
    final generation = _loadGeneration;
    if (rawUrl.isEmpty || widget.localImagePath?.trim().isNotEmpty == true) {
      return;
    }
    var path = await AvatarPreloadService.localPathFor(rawUrl);
    if (path == null) {
      await AvatarPreloadService.warm(
        rawUrl,
        cacheIdentity: widget.cacheIdentity,
      );
      path = await AvatarPreloadService.localPathFor(rawUrl);
    }
    if (!mounted ||
        generation != _loadGeneration ||
        widget.imageUrl?.trim() != rawUrl ||
        widget.imageUrl?.trim().isEmpty == true ||
        path == null ||
        path == _lastGoodLocalImagePath) {
      return;
    }
    _knownGoodLocalPaths.add(path);
    setState(() => _lastGoodLocalImagePath = path);
    apkLog(
      'Avatar.load',
      'state="local_file_ready" path="$path" url="${_resolveImageUrl(rawUrl)}"',
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget avatarWidget;

    if (widget.suppressAvatar) {
      return _wrapAvatar(_buildPlaceholder());
    }

    if (widget.isDeleted) {
      return _wrapAvatar(_buildDeletedGhost());
    }

    final localFile = _localImageFile();

    final imageUrl = _effectiveImageUrl();
    final cachedProvider = imageUrl.isNotEmpty
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
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return _buildPlaceholder();
          },
          cacheWidth: (widget.size * MediaQuery.devicePixelRatioOf(context))
              .round(),
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
      _logPaintOnce(imageUrl, source: 'memory_cache');
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
    final logIdentity = widget.cacheIdentity?.trim().isNotEmpty == true
        ? widget.cacheIdentity!.trim()
        : providerKey;
    if (_loggedLoadKeys.add(providerKey)) {
      apkLog(
        'Avatar.load',
        'state="started" identity="$logIdentity" '
            'size=${widget.size} url="$url"',
      );
    }
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        cacheKey: providerKey,
        imageBuilder: (context, imageProvider) {
          if (!mounted || widget.imageUrl?.trim() != rawUrl) {
            return _buildPlaceholder();
          }
          _lastGoodImageUrl = rawUrl;
          // Remember this provider so every future build (including in
          // other UserAvatar instances for the same URL — other screens,
          // conversation tiles, profile page, etc.) can skip straight to
          // painting it with zero placeholder frame.
          _resolvedImageCache[providerKey] = imageProvider;
          _logPaintOnce(rawUrl, source: 'network_or_disk_cache');
          return Image(
            image: imageProvider,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
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
        useOldImageOnUrlChange: false,
        placeholder: (context, url) => _buildPlaceholder(),
        errorWidget: (context, url, error) {
          debugPrint('[UserAvatar] image load failed url="$url" error=$error');
          apkLog(
            'Avatar.load',
            'state="failed" identity="$logIdentity" '
                'size=${widget.size} url="$url" error="$error"',
          );
          return _buildPlaceholder();
        },
      ),
    );
  }

  void _logPaintOnce(String rawUrl, {required String source}) {
    final key = _providerCacheKey(rawUrl);
    if (!_loggedPaintKeys.add(key)) return;
    final logIdentity = widget.cacheIdentity?.trim().isNotEmpty == true
        ? widget.cacheIdentity!.trim()
        : key;
    apkLog(
      'Avatar.load',
      'state="painted" source="$source" '
          'identity="$logIdentity" size=${widget.size} '
          'url="${_resolveImageUrl(rawUrl)}"',
    );
  }

  String _providerCacheKey(String rawUrl) {
    final url = _resolveImageUrl(rawUrl);
    // The avatar URL is the canonical image identity across home, chat, and
    // profile surfaces. Surface-specific cacheIdentity values are retained
    // for diagnostics only; including them here would create three separate
    // resolved providers for the same avatar and allow visible timing drift.
    return url;
  }

  static String _resolveImageUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
    if (url.startsWith('mxc://')) return _resolveMxcUrl(url);
    return url.startsWith('/') ? '${ApiService.baseUrl}$url' : url;
  }

  static String _resolveMxcUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isScheme('mxc')) return '';
    final mediaId = uri.pathSegments.join('/');
    if (uri.host.isEmpty || mediaId.isEmpty) return '';
    final homeserver = Uri.tryParse(MatrixConfig.homeserver);
    if (homeserver == null || !homeserver.hasScheme) return '';
    final downloadUri = homeserver.resolve(
      '/_matrix/client/v1/media/download/'
      '${Uri.encodeComponent(uri.host)}/'
      '${Uri.encodeComponent(mediaId)}',
    );
    final version = uri.queryParameters['v'];
    return downloadUri
        .replace(queryParameters: version == null ? null : {'v': version})
        .toString();
  }

  static String _stripVersion(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return url;
    final params = Map<String, String>.from(uri.queryParameters)..remove('v');
    return uri
        .replace(queryParameters: params.isEmpty ? null : params)
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
        ApiService.isBackendHost(uri?.host) ||
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
        child: initials != null
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
