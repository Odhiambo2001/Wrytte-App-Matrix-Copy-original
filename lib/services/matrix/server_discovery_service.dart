import 'dart:convert';

import 'package:http/http.dart' as http;

class ServerDiscoveryService {
  ServerDiscoveryService({
    http.Client? httpClient,
    this.defaultHomeserver = 'https://matrix.org',
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final String defaultHomeserver;

  Future<Uri> resolveHomeserver({String? userIdOrDomain}) async {
    final domain = _domainFrom(userIdOrDomain);
    if (domain == null || domain.isEmpty) {
      return Uri.parse(defaultHomeserver);
    }

    final wellKnown = Uri.https(domain, '/.well-known/matrix/client');
    try {
      final response = await _httpClient
          .get(wellKnown)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return Uri.https(domain, '');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final baseUrl = (data['m.homeserver'] as Map<String, dynamic>?)?['base_url']
          ?.toString();
      if (baseUrl == null || baseUrl.isEmpty) return Uri.https(domain, '');
      return Uri.parse(baseUrl);
    } catch (_) {
      return Uri.https(domain, '');
    }
  }

  String? _domainFrom(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('@') && raw.contains(':')) return raw.split(':').last;
    if (raw.contains('@') && raw.contains('.')) return raw.split('@').last;
    if (raw.contains('.') && !raw.contains(' ')) return raw;
    return null;
  }
}
