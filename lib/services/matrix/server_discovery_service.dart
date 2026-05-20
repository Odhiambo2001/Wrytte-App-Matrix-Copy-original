import 'dart:convert';

import 'package:http/http.dart' as http;

import 'matrix_config.dart';

class ServerDiscoveryService {
  ServerDiscoveryService({
    http.Client? httpClient,
    this.defaultHomeserver = MatrixConfig.homeserver,
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final String defaultHomeserver;

  Future<Uri> resolveHomeserver({String? userIdOrDomain}) async {
    final explicit = _explicitHomeserverUri(userIdOrDomain);
    if (explicit != null) return explicit;

    final domain = _domainFrom(userIdOrDomain);
    if (domain == null || domain.isEmpty) {
      return _homeserverUri(defaultHomeserver);
    }

    final wellKnown = Uri.https(domain, '/.well-known/matrix/client');
    try {
      final response = await _httpClient
          .get(wellKnown)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _homeserverUri(domain);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final baseUrl =
          (data['m.homeserver'] as Map<String, dynamic>?)?['base_url']
              ?.toString();
      if (baseUrl == null || baseUrl.isEmpty) return _homeserverUri(domain);
      return _homeserverUri(baseUrl);
    } catch (_) {
      return _homeserverUri(domain);
    }
  }

  String? _domainFrom(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('@') && raw.contains(':')) return raw.split(':').last;
    if (raw.contains('@') && raw.contains('.')) return raw.split('@').last;
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) return uri.host;
    if (raw.contains('.') && !raw.contains(' ')) return raw;
    return null;
  }

  Uri? _explicitHomeserverUri(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri;
  }

  Uri _homeserverUri(String value) {
    final raw = value.trim();
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) return uri;
    return Uri.https(raw, '');
  }
}
