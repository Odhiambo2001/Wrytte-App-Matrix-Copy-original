import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wrytte/ui/widgets/wrytte_persistent_image.dart';

String? firstLinkInText(String text) {
  final match = RegExp(
    r'((?:https?:\/\/|www\.)[^\s]+|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:\/[^\s]*)?)',
  ).firstMatch(text);
  final raw = match?.group(0)?.replaceFirst(RegExp(r'[),.;:!?]+$'), '');
  if (raw == null || raw.isEmpty) return null;
  if (_looksLikeAttachmentFileName(raw)) return null;
  return raw.startsWith('http') ? raw : 'https://$raw';
}

bool _looksLikeAttachmentFileName(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return false;
  }
  return RegExp(
    r'\.(png|jpe?g|gif|webp|bmp|heic|heif|mp4|mov|m4v|webm|mkv|3gp|pdf|docx?|pptx?|xlsx?|txt|csv|zip|rar|7z|apk)$',
  ).hasMatch(trimmed);
}

String linkDisplayDomain(String value) {
  final normalized =
      value.trim().startsWith('http')
          ? value.trim()
          : 'https://${value.trim()}';
  final host = Uri.tryParse(normalized)?.host ?? value.trim();
  return host.replaceFirst(RegExp(r'^www\.'), '');
}

String linkDisplayRootUrl(String value) {
  final trimmed = value.trim();
  final normalized = trimmed.startsWith('http') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(normalized);
  if (uri == null || uri.host.isEmpty) return trimmed;
  final host = uri.host.startsWith('www.') ? uri.host : 'www.${uri.host}';
  return '${uri.scheme}://$host';
}

String linkDisplayText(String text) {
  final link = firstLinkInText(text);
  if (link == null) return text;
  final withoutLink =
      text
          .replaceFirst(RegExp(RegExp.escape(link), caseSensitive: false), '')
          .trim();
  if (withoutLink.isNotEmpty) return text;
  return linkDisplayRootUrl(link);
}

class WrytteLinkPreview extends StatefulWidget {
  final String url;
  final bool showOriginalUrl;
  final bool compact;

  const WrytteLinkPreview({
    super.key,
    required this.url,
    this.showOriginalUrl = false,
    this.compact = false,
  });

  @override
  State<WrytteLinkPreview> createState() => _WrytteLinkPreviewState();
}

class _WrytteLinkPreviewState extends State<WrytteLinkPreview> {
  static final Map<String, Future<_LinkMetadata>> _metadataCache = {};
  late Future<_LinkMetadata> _metadata;

  @override
  void initState() {
    super.initState();
    _metadata = _metadataFor(widget.url);
  }

  @override
  void didUpdateWidget(covariant WrytteLinkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _metadata = _metadataFor(widget.url);
  }

  Future<_LinkMetadata> _metadataFor(String value) {
    final url = _normalize(value);
    return _metadataCache.putIfAbsent(url, () => _loadMetadata(url));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LinkMetadata>(
      future: _metadata,
      builder: (context, snapshot) {
        final url = _normalize(widget.url);
        if (!snapshot.hasData) return _loadingPreview();
        final metadata = snapshot.data!;
        if (widget.compact) return _compactPreview(metadata, url);
        return InkWell(
          onTap: () => _open(url),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (metadata.imageUrl != null)
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: WryttePersistentImage(
                      source: metadata.imageUrl!,
                      fit: BoxFit.cover,
                      placeholder: _domainPlaceholder(metadata),
                      errorWidget: _domainPlaceholder(metadata),
                    ),
                  )
                else
                  _domainPlaceholder(metadata),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        metadata.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      if (metadata.description.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          metadata.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        metadata.domain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      if (widget.showOriginalUrl) ...[
                        const SizedBox(height: 8),
                        Text(
                          linkDisplayRootUrl(url),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF9CCFFF),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _loadingPreview() {
    final height = widget.compact ? 105.0 : 190.0;
    return SizedBox(
      height: height,
      child: const ColoredBox(color: Color(0xFF141920)),
    );
  }

  Widget _domainPlaceholder(_LinkMetadata metadata) {
    return Container(
      height: 86,
      color: const Color(0xFF141920),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ColorFiltered(
            colorFilter: const ColorFilter.matrix([
              0, 0, 0, 0, 255,
              0, 0, 0, 0, 255,
              0, 0, 0, 0, 255,
              1, 0, 0, 0, 0,
            ]),
            child: SizedBox(
              width: 22,
              height: 22,
              child: Transform.scale(
                scaleX: -1,
                child: SvgPicture.asset(
                  'assets/images/link_icon.svg',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(metadata.domain, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _compactPreview(_LinkMetadata metadata, String url) {
    return InkWell(
      onTap: () => _open(url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    width: 82,
                    height: 82,
                    child:
                        metadata.imageUrl != null
                            ? WryttePersistentImage(
                              source: metadata.imageUrl!,
                              fit: BoxFit.cover,
                              placeholder: _compactPlaceholder(),
                              errorWidget: _compactPlaceholder(),
                            )
                            : _compactPlaceholder(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        metadata.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (metadata.description.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          metadata.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const SizedBox(height: 3),
                      Text(
                        metadata.domain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    linkDisplayRootUrl(url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white38,
                  size: 20,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactPlaceholder() {
    return ColoredBox(
      color: Color(0xFF11161C),
      child: Center(
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0, 0, 0, 0, 255,
            0, 0, 0, 0, 255,
            0, 0, 0, 0, 255,
            1, 0, 0, 0, 0,
          ]),
          child: SizedBox(
            width: 22,
            height: 22,
            child: Transform.scale(
              scaleX: -1,
              child: SvgPicture.asset(
                'assets/images/link_icon.svg',
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Future<_LinkMetadata> _loadMetadata(String url) async {
    final preferences = await SharedPreferences.getInstance();
    final cacheKey = _cacheKey(url);
    final cached = preferences.getString(cacheKey);
    if (cached != null) {
      try {
        return _LinkMetadata.fromJson(
          Map<String, dynamic>.from(jsonDecode(cached) as Map),
        );
      } catch (_) {
        await preferences.remove(cacheKey);
      }
    }
    try {
      final uri = Uri.parse(url);
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] = 'Mozilla/5.0 WrytteLinkPreview/1.0';
      final response = await request.send().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode < 200 || response.statusCode >= 400) {
        return _LinkMetadata.fallback(url);
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 10),
      )) {
        final remaining = 262144 - bytes.length;
        if (remaining <= 0) break;
        bytes.addAll(chunk.take(remaining));
      }
      final html = utf8.decode(bytes, allowMalformed: true);
      final title = _meta(html, 'og:title') ?? _title(html);
      final description =
          _meta(html, 'og:description') ?? _meta(html, 'description') ?? '';
      final rawImage = _meta(html, 'og:image');
      final image = rawImage == null ? null : uri.resolve(rawImage).toString();
      final metadata = _LinkMetadata(
        title: _clean(title) ?? uri.host,
        description: _clean(description) ?? '',
        imageUrl: image,
        domain: uri.host.replaceFirst(RegExp(r'^www\.'), ''),
      );
      await preferences.setString(cacheKey, jsonEncode(metadata.toJson()));
      return metadata;
    } catch (_) {
      return _LinkMetadata.fallback(url);
    }
  }

  static String _cacheKey(String url) =>
      'wrytte.link_preview.${base64Url.encode(utf8.encode(url))}';

  static String? _meta(String html, String key) {
    for (final tag in RegExp(
      r'<meta\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final value = tag.group(0) ?? '';
      final property = RegExp(
        r'''(?:property|name)\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(value)?.group(1);
      if (property?.toLowerCase() != key.toLowerCase()) continue;
      return RegExp(
        r'''content\s*=\s*["']([^"']*)["']''',
        caseSensitive: false,
      ).firstMatch(value)?.group(1);
    }
    return null;
  }

  static String? _title(String html) => RegExp(
    r'<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html)?.group(1);

  static String? _clean(String? value) {
    final clean =
        value
            ?.replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

  static Future<void> _open(String value) async {
    final uri = Uri.tryParse(value);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static String _normalize(String value) {
    final trimmed = value.trim();
    return trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'https://$trimmed';
  }
}

class _LinkMetadata {
  final String title;
  final String description;
  final String? imageUrl;
  final String domain;

  const _LinkMetadata({
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.domain,
  });

  factory _LinkMetadata.fromJson(Map<String, dynamic> json) {
    return _LinkMetadata(
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString(),
      domain: json['domain']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'description': description,
    'imageUrl': imageUrl,
    'domain': domain,
  };

  factory _LinkMetadata.fallback(String url) {
    final uri = Uri.tryParse(url);
    final domain = uri?.host.replaceFirst(RegExp(r'^www\.'), '') ?? url;
    return _LinkMetadata(
      title: domain,
      description: '',
      imageUrl: null,
      domain: domain,
    );
  }
}
