import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';

/// Local SQLite cache for fast startup and offline chat access.
/// Matrix/Dendrite remains the canonical message store; this cache mirrors
/// recent timelines plus device-local flags such as "delete for me" and star.
class ChatLocalDb {
  ChatLocalDb._();
  static final ChatLocalDb instance = ChatLocalDb._();

  static const _userIdKey = 'user_id';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Database? _db;
  String? _ownerId;

  Future<Database> get db async {
    final ownerId = await _currentOwnerId();
    if (_db != null && _ownerId != ownerId) {
      await _db!.close();
      _db = null;
    }
    _ownerId = ownerId;
    _db ??= await _open(ownerId);
    return _db!;
  }

  // ── Sanitise strings coming out of SQLite ──────────────────────────────────
  // Strips lone surrogates (U+D800–U+DFFF) that crash Flutter's text renderer.
  // Applied to every user-supplied string field on read so bad data stored in
  // previous sessions can never reach a Text widget.
  static String _sanitize(String s) {
    return String.fromCharCodes(
      s.runes.where((r) => r <= 0xD7FF || r >= 0xE000),
    );
  }

  // ── Open / migrate ─────────────────────────────────────────────────────────

  Future<Database> _open(String ownerId) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'wrytte_chat_${_dbOwnerKey(ownerId)}.db');

    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id               TEXT PRIMARY KEY,
            conversationId   TEXT NOT NULL,
            senderId         TEXT NOT NULL,
            receiverId       TEXT NOT NULL,
            content          TEXT NOT NULL,
            timestamp        INTEGER NOT NULL,
            status           TEXT NOT NULL,
            attachmentUrl    TEXT,
            attachmentType   TEXT,
            voiceDuration    INTEGER,
            replyToMessageId TEXT,
            replyToSenderId  TEXT,
            replyPreview     TEXT,
            isForwarded      INTEGER NOT NULL DEFAULT 0,
            isStarred        INTEGER NOT NULL DEFAULT 0,
            isDeletedForMe   INTEGER NOT NULL DEFAULT 0,
            isDeletedForEveryone INTEGER NOT NULL DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_messages_conv
          ON messages (conversationId, timestamp)
        ''');

        await db.execute('''
          CREATE INDEX idx_messages_starred
          ON messages (isStarred, timestamp)
        ''');

        await db.execute('''
          CREATE TABLE conversations (
            id                   TEXT PRIMARY KEY,
            participants         TEXT NOT NULL,
            otherUserId          TEXT NOT NULL,
            lastMessage          TEXT NOT NULL,
            lastMessageSenderId  TEXT NOT NULL,
            lastMessageTime      INTEGER NOT NULL,
            unreadCount          INTEGER NOT NULL DEFAULT 0,
            lastMessageType      TEXT NOT NULL DEFAULT 'text',
            isArchived           INTEGER NOT NULL DEFAULT 0,
            isMuted              INTEGER NOT NULL DEFAULT 0,
            isPinned             INTEGER NOT NULL DEFAULT 0,
            otherUserName        TEXT,
            otherUserAvatar      TEXT
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_conversations_time
          ON conversations (lastMessageTime DESC)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _addColumnIfMissing(db, 'messages', 'voiceDuration', 'INTEGER');
          await _addColumnIfMissing(db, 'messages', 'replyToMessageId', 'TEXT');
          await _addColumnIfMissing(db, 'messages', 'replyToSenderId', 'TEXT');
          await _addColumnIfMissing(db, 'messages', 'replyPreview', 'TEXT');
          await _addColumnIfMissing(
            db,
            'messages',
            'isForwarded',
            'INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            'messages',
            'isStarred',
            'INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            'messages',
            'isDeletedForMe',
            'INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            'messages',
            'isDeletedForEveryone',
            'INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute('''
            CREATE INDEX IF NOT EXISTS idx_messages_starred
            ON messages (isStarred, timestamp)
          ''');
        }
      },
    );
  }

  Future<String> _currentOwnerId() async {
    final userId = await _storage.read(key: _userIdKey);
    final normalized = userId?.trim();
    if (normalized == null || normalized.isEmpty) return 'signed_out';
    return normalized;
  }

  String _dbOwnerKey(String ownerId) {
    final key = ownerId.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '_');
    return key.isEmpty ? 'signed_out' : key;
  }

  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((row) => row['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  /// Insert or replace a batch of messages in a single transaction.
  Future<void> saveMessages(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    final database = await db;
    final batch = database.batch();

    for (final m in messages) {
      batch.insert('messages', {
        'id': m.id,
        'conversationId': m.conversationId,
        'senderId': m.senderId,
        'receiverId': m.receiverId,
        'content': m.content,
        'timestamp': m.timestamp.millisecondsSinceEpoch,
        'status': m.status.name,
        'attachmentUrl': m.attachmentUrl,
        'attachmentType': m.attachmentType,
        'voiceDuration': m.voiceDuration,
        'replyToMessageId': m.replyToMessageId,
        'replyToSenderId': m.replyToSenderId,
        'replyPreview': m.replyPreview,
        'isForwarded': m.isForwarded ? 1 : 0,
        'isStarred': m.isStarred ? 1 : 0,
        'isDeletedForMe': m.isDeletedForMe ? 1 : 0,
        'isDeletedForEveryone': m.isDeletedForEveryone ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  /// Save a single message — used on optimistic send and on receive.
  Future<void> saveMessage(ChatMessage message) => saveMessages([message]);

  Future<void> deleteDuplicateOutgoingEchoesFor(ChatMessage canonical) async {
    if (_isLocalOutgoingEchoId(canonical.id)) return;

    final database = await db;
    final timestamp = canonical.timestamp.millisecondsSinceEpoch;
    final rows = await database.query(
      'messages',
      columns: ['id', 'senderId', 'receiverId'],
      where: '''
        id != ?
        AND content = ?
        AND timestamp BETWEEN ? AND ?
        AND (id LIKE ? OR id LIKE ? OR status = ?)
      ''',
      whereArgs: [
        canonical.id,
        canonical.content,
        timestamp - 60000,
        timestamp + 60000,
        'opt_%',
        'Wrytte-%',
        MessageStatus.sending.name,
      ],
    );

    final canonicalSender = _messagePeerKey(canonical.senderId);
    final canonicalReceiver = _messagePeerKey(canonical.receiverId);
    final duplicateIds =
        rows
            .where((row) {
              final sender = _messagePeerKey(row['senderId'] as String? ?? '');
              final receiver = _messagePeerKey(
                row['receiverId'] as String? ?? '',
              );
              return sender == canonicalSender && receiver == canonicalReceiver;
            })
            .map((row) => row['id'] as String)
            .toList();

    if (duplicateIds.isEmpty) return;

    final placeholders = List.filled(duplicateIds.length, '?').join(',');
    await database.delete(
      'messages',
      where: 'id IN ($placeholders)',
      whereArgs: duplicateIds,
    );
  }

  /// Load all messages for a conversation, oldest first.
  Future<List<ChatMessage>> loadMessages(String conversationId) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(_rowToMessage).toList();
  }

  ChatMessage _rowToMessage(Map<String, dynamic> row) {
    return ChatMessage(
      id: row['id'] as String,
      conversationId: row['conversationId'] as String,
      senderId: row['senderId'] as String,
      receiverId: row['receiverId'] as String,
      content: _sanitize(row['content'] as String),
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      status: MessageStatus.values.firstWhere(
        (s) => s.name == row['status'],
        orElse: () => MessageStatus.sent,
      ),
      attachmentUrl: row['attachmentUrl'] as String?,
      attachmentType: row['attachmentType'] as String?,
      voiceDuration: row['voiceDuration'] as int?,
      replyToMessageId: row['replyToMessageId'] as String?,
      replyToSenderId: row['replyToSenderId'] as String?,
      replyPreview: row['replyPreview'] as String?,
      isForwarded: (row['isForwarded'] as int? ?? 0) == 1,
      isStarred: (row['isStarred'] as int? ?? 0) == 1,
      isDeletedForMe: (row['isDeletedForMe'] as int? ?? 0) == 1,
      isDeletedForEveryone: (row['isDeletedForEveryone'] as int? ?? 0) == 1,
    );
  }

  Future<void> setMessageStarred(String messageId, bool isStarred) async {
    final database = await db;
    await database.update(
      'messages',
      {'isStarred': isStarred ? 1 : 0},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> deleteMessageForMe(String messageId) async {
    final database = await db;
    await database.update(
      'messages',
      {'isDeletedForMe': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> markMessageDeletedForEveryone(String messageId) async {
    final database = await db;
    await database.update(
      'messages',
      {'isDeletedForEveryone': 1, 'content': 'This message was deleted'},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<List<ChatMessage>> loadStarredMessages() async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where: 'isStarred = ? AND isDeletedForMe = ?',
      whereArgs: [1, 0],
      orderBy: 'timestamp DESC',
    );
    return rows.map(_rowToMessage).toList();
  }

  // ── Conversations ──────────────────────────────────────────────────────────

  /// Upsert a list of conversations — preserves cached name/avatar if already stored.
  Future<void> saveConversations(List<ChatConversation> conversations) async {
    if (conversations.isEmpty) return;
    final database = await db;

    for (final c in conversations) {
      // Read existing row so we don't overwrite a cached name/avatar with null
      final existing = await database.query(
        'conversations',
        where: 'id = ?',
        whereArgs: [c.id],
        limit: 1,
      );

      final existingName =
          existing.isNotEmpty
              ? existing.first['otherUserName'] as String?
              : null;
      final existingAvatar =
          existing.isNotEmpty
              ? existing.first['otherUserAvatar'] as String?
              : null;

      await database.insert('conversations', {
        'id': c.id,
        'participants': c.participants.join(','),
        'otherUserId': c.otherUserId,
        'lastMessage': c.lastMessage,
        'lastMessageSenderId': c.lastMessageSenderId,
        'lastMessageTime': c.lastMessageTime.millisecondsSinceEpoch,
        'unreadCount': c.unreadCount,
        'lastMessageType': c.lastMessageType,
        'isArchived': c.isArchived ? 1 : 0,
        'isMuted': c.isMuted ? 1 : 0,
        'isPinned': c.isPinned ? 1 : 0,
        // Keep existing cached name/avatar — don't overwrite with null
        'otherUserName': c.otherUserName ?? existingName,
        'otherUserAvatar': c.otherUserAvatar ?? existingAvatar,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Update name + avatar for a conversation after Matrix contact or profile enrichment.
  Future<void> updateConversationUserInfo({
    required String conversationId,
    required String name,
    String? avatar,
  }) async {
    final database = await db;
    await database.update(
      'conversations',
      {'otherUserName': name, 'otherUserAvatar': avatar},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// Load all conversations from SQLite, newest first.
  /// Names and last messages are sanitized on read to strip any bad UTF-16
  /// that may have been written by a previous version of the app.
  Future<List<ChatConversation>> loadConversations() async {
    final database = await db;
    final rows = await database.query(
      'conversations',
      orderBy: 'lastMessageTime DESC',
    );
    return rows.map(_rowToConversation).toList();
  }

  Future<String?> findDirectConversationId({
    required String selfUserId,
    required String otherUserId,
  }) async {
    final self = _conversationPeerKey(selfUserId);
    final other = _conversationPeerKey(otherUserId);
    if (self.isEmpty || other.isEmpty) return null;

    final conversations = await loadConversations();
    ChatConversation? fallback;
    for (final conversation in conversations) {
      final participants =
          conversation.participants.map(_conversationPeerKey).toSet();
      final otherId = _conversationPeerKey(conversation.otherUserId);
      final hasBothParticipants =
          participants.contains(self) && participants.contains(other);
      final hasOtherUser = otherId == other;
      if (!hasBothParticipants && !hasOtherUser) continue;
      if (conversation.id.startsWith('!')) return conversation.id;
      fallback ??= conversation;
    }
    return fallback?.id;
  }

  ChatConversation _rowToConversation(Map<String, dynamic> row) {
    final participantsRaw = row['participants'] as String? ?? '';
    final participants =
        participantsRaw.isNotEmpty ? participantsRaw.split(',') : <String>[];

    // Sanitize every user-supplied text field to strip lone surrogates
    final rawName = row['otherUserName'] as String?;
    final rawLastMessage = row['lastMessage'] as String;

    return ChatConversation(
      id: row['id'] as String,
      participants: participants,
      otherUserId: row['otherUserId'] as String,
      lastMessage: _sanitize(rawLastMessage),
      lastMessageSenderId: row['lastMessageSenderId'] as String? ?? '',
      lastMessageTime: DateTime.fromMillisecondsSinceEpoch(
        row['lastMessageTime'] as int,
      ),
      unreadCount: row['unreadCount'] as int,
      lastMessageType: row['lastMessageType'] as String? ?? 'text',
      isArchived: (row['isArchived'] as int? ?? 0) == 1,
      isMuted: (row['isMuted'] as int? ?? 0) == 1,
      isPinned: (row['isPinned'] as int? ?? 0) == 1,
      otherUserName: rawName != null ? _sanitize(rawName) : null,
      otherUserAvatar: row['otherUserAvatar'] as String?,
    );
  }

  // ── Mark conversation as read ──────────────────────────────────────────────

  Future<void> markConversationRead(String conversationId) async {
    final database = await db;
    await database.update(
      'conversations',
      {'unreadCount': 0},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  // ── Clear cached user names — call once to flush stale data ───────────────

  Future<void> clearConversationUserNames() async {
    final database = await db;
    await database.update('conversations', {
      'otherUserName': null,
      'otherUserAvatar': null,
    });
  }

  String _conversationPeerKey(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
  }

  bool _isLocalOutgoingEchoId(String id) {
    return id.startsWith('opt_') || id.startsWith('Wrytte-');
  }

  String _messagePeerKey(String value) {
    return _conversationPeerKey(value);
  }

  // ── Full wipe — call on logout ─────────────────────────────────────────────

  Future<void> clearAll() async {
    final database = await db;
    await database.delete('messages');
    await database.delete('conversations');
  }
}
