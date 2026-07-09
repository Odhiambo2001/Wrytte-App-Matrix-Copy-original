import 'package:matrix/matrix.dart' as mx;
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';

class ContactAvatarSanitizer {
  const ContactAvatarSanitizer._();

  static List<Contact> sanitizeAll(Iterable<Contact> contacts) {
    return contacts.map(sanitize).toList();
  }

  static Contact sanitize(Contact contact) {
    final cleanAvatar = sanitizeAvatarUrl(contact.avatarUrl);
    if (cleanAvatar == contact.avatarUrl) return contact;
    return Contact(
      displayName: contact.displayName,
      phones: contact.phones,
      avatarUrl: cleanAvatar,
      bio: contact.bio,
      isOnWrytte: contact.isOnWrytte,
      wrytteUserId: contact.wrytteUserId,
      databaseName: contact.databaseName,
      isRecent: contact.isRecent,
      isSaved: contact.isSaved,
    );
  }

  static String? sanitizeAvatarUrl(String? avatarUrl) {
    final clean = avatarUrl?.trim() ?? '';
    if (clean.isEmpty) return null;
    if (_matchesKnownGroupAvatar(clean)) return null;
    return clean;
  }

  static bool _matchesKnownGroupAvatar(String avatarUrl) {
    final normalized = _normaliseAvatarIdentity(avatarUrl);
    if (normalized.isEmpty) return false;
    for (final room in MatrixChatService.instance.rooms) {
      if (!MatrixChatService.instance.isMatrixGroupRoom(room)) continue;
      for (final candidate in _groupAvatarCandidates(room)) {
        if (_normaliseAvatarIdentity(candidate) == normalized) return true;
      }
    }
    return false;
  }

  static Iterable<String?> _groupAvatarCandidates(mx.Room room) sync* {
    yield room.avatar?.toString();
    final raw = room.getState(mx.EventTypes.RoomAvatar)?.content['url'];
    if (raw is String) yield raw;
  }

  static String _normaliseAvatarIdentity(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;
    if (uri.scheme == 'mxc') {
      return 'mxc://${uri.host}${uri.path}';
    }
    return trimmed;
  }
}
