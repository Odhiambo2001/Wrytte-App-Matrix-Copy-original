class AuthUser {
  final String userId;
  final String username;
  final String secret;
  final String token;
  final String? phone;
  final DateTime? expiresAt;

  AuthUser({
    required this.userId,
    required this.username,
    required this.secret,
    required this.token,
    this.phone,
    this.expiresAt,
  });

  bool get isAuthenticated => userId.isNotEmpty || token.isNotEmpty;

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      userId: json['userid'] ?? json['userId'] ?? '',
      username: json['username'] ?? '',
      secret: json['secret'] ?? '',
      token: json['token'] ?? '',
      phone: json['phone'],
      expiresAt:
          json['expires'] != null
              ? DateTime.tryParse(json['expires'])
              : json['expiresAt'] != null
              ? DateTime.tryParse(json['expiresAt'])
              : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userid': userId,
      'username': username,
      'secret': secret,
      'token': token,
      'phone': phone,
      'expires': expiresAt?.toIso8601String(),
    };
  }
}
