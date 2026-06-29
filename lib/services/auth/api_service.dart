import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class ApiService {
  static const String baseUrl = String.fromEnvironment(
    'WRYTTE_BACKEND_API_URL',
    defaultValue: 'https://wryttedev.azurewebsites.net',
  );

  // POST (x-www-form-urlencoded)

  static Future<dynamic> post(
    String path, {
    Map<String, dynamic>? body,
    Map<String, dynamic>? queryParameters,
    String? token,
  }) async {
    final uri = Uri.parse(
      "$baseUrl$path",
    ).replace(queryParameters: queryParameters);

    final headers = {
      "Content-Type": "application/x-www-form-urlencoded",
      if (token != null) "Authorization": "Bearer $token",
    };

    debugPrint("➡️ POST $uri");
    debugPrint("📦 BODY: ${_redactMap(body)}");

    final response = await http
        .post(
          uri,
          headers: headers,
          body: body?.map((k, v) => MapEntry(k, v?.toString() ?? "")),
        )
        .timeout(const Duration(seconds: 20));

    debugPrint("⬅️ STATUS: ${response.statusCode}");
    debugPrint("⬅️ RESPONSE: ${response.body}");

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _safeDecode(response.body);
    }

    throw ApiException(response.statusCode, response.body);
  }

  // POST (application/json)

  static Future<dynamic> postJson(
    String path, {
    Map<String, dynamic>? body,
    Map<String, dynamic>? queryParameters,
    String? token,
  }) async {
    final uri = Uri.parse(
      "$baseUrl$path",
    ).replace(queryParameters: queryParameters);

    final headers = {
      "Content-Type": "application/json",
      "Accept": "application/json",
      if (token != null && token.isNotEmpty) "Authorization": "Bearer $token",
    };

    debugPrint("➡️ POST JSON $uri");
    debugPrint("📦 JSON BODY: ${_redactMap(body)}");

    final response = await http
        .post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const <String, dynamic>{}),
        )
        .timeout(const Duration(seconds: 20));

    debugPrint("⬅️ STATUS: ${response.statusCode}");
    debugPrint("⬅️ RESPONSE: ${response.body}");

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _safeDecode(response.body);
    }

    throw ApiException(response.statusCode, response.body);
  }

  // DELETE (application/json)

  static Future<dynamic> deleteJson(
    String path, {
    Map<String, dynamic>? body,
    Map<String, dynamic>? queryParameters,
    String? token,
  }) async {
    final uri = Uri.parse(
      "$baseUrl$path",
    ).replace(queryParameters: queryParameters);

    final headers = {
      "Content-Type": "application/json",
      "Accept": "application/json",
      if (token != null && token.isNotEmpty) "Authorization": "Bearer $token",
    };

    debugPrint("➡️ DELETE JSON $uri");
    debugPrint("📦 JSON BODY: ${_redactMap(body)}");

    final request =
        http.Request('DELETE', uri)
          ..headers.addAll(headers)
          ..body = jsonEncode(body ?? const <String, dynamic>{});

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 20),
    );
    final response = await http.Response.fromStream(streamedResponse);

    debugPrint("⬅️ STATUS: ${response.statusCode}");
    debugPrint("⬅️ RESPONSE: ${response.body}");

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _safeDecode(response.body);
    }

    throw ApiException(response.statusCode, response.body);
  }

  // POST (multipart/form-data)

  static Future<dynamic> postMultipart(
    String path,
    Map<String, String> fields, {
    List<http.MultipartFile> files = const [],
    String? token,
  }) async {
    final uri = Uri.parse("$baseUrl$path");

    final request = http.MultipartRequest("POST", uri);
    request.fields.addAll(fields);
    request.files.addAll(files);

    if (token != null) {
      request.headers["Authorization"] = "Bearer $token";
    }

    debugPrint("➡️ POST MULTIPART $uri");
    debugPrint("📦 FIELDS: ${_redactMap(fields)}");
    if (files.isNotEmpty) {
      debugPrint("📎 FILES: ${files.map((file) => file.field).join(', ')}");
    }

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 20),
    );

    final response = await http.Response.fromStream(streamedResponse);

    debugPrint("⬅️ STATUS: ${response.statusCode}");
    debugPrint("⬅️ RESPONSE: ${response.body}");

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _safeDecode(response.body);
    }

    throw ApiException(response.statusCode, response.body);
  }

  // GET

  static Future<dynamic> get(
    String path, {
    String? token,
    Map<String, dynamic>? queryParameters,
  }) async {
    final uri = Uri.parse("$baseUrl$path").replace(
      queryParameters: queryParameters?.map(
        (k, v) => MapEntry(k, v?.toString() ?? ""),
      ),
    );

    final headers = {
      "Content-Type": "application/x-www-form-urlencoded",
      if (token != null) "Authorization": "Bearer $token",
    };

    debugPrint("➡️ GET $uri");

    final response = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));

    debugPrint("⬅️ STATUS: ${response.statusCode}");
    debugPrint("⬅️ RESPONSE: ${response.body}");

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _safeDecode(response.body);
    }

    throw ApiException(response.statusCode, response.body);
  }

  // SAFE JSON DECODER

  static dynamic _safeDecode(String body) {
    if (body.isEmpty) return null;

    try {
      final decoded = jsonDecode(body);

      if (decoded is int || decoded is bool || decoded is String) {
        debugPrint("⚠️ Primitive JSON received: $decoded");
        return {"value": decoded};
      }

      return decoded;
    } catch (e) {
      debugPrint("⚠️ JSON decode error: $e");
      debugPrint("⚠️ Non-JSON response received, treating as success");
      return null;
    }
  }

  static Map<String, dynamic>? _redactMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    return map.map((key, value) {
      final lowerKey = key.toLowerCase();
      final shouldRedact =
          lowerKey.contains('secret') ||
          lowerKey.contains('token') ||
          lowerKey.contains('password');
      return MapEntry(key, shouldRedact ? '***' : value);
    });
  }
}

// API Exception

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => "API Error [$statusCode]: $message";
}
