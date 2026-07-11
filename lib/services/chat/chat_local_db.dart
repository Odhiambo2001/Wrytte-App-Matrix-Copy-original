import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';

/// Local SQLite cache for fast startup and offline chat access.
/// Matrix/Dendrite remains the canonical message store; this cache mirrors
/// recent timelines plus device-local flags such as "delete for me" and star.
class ChatLocalDb {
  ChatLocalDb._();
  static final ChatLocalDb instance = ChatLocalDb._();

  static const _userIdKey = 'user_id';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Database? _db;
  String? _ownerId;
  String? _boundOwnerId;

  Future<void> bindOwner(String? ownerUserId) async {
    final normalized = ownerUserId?.trim();
    final nextOwner =
        normalized == null || normalized.isEmpty ? null : normalized;
    if (_boundOwnerId == nextOwner) return;
    _boundOwnerId = nextOwner;
    if (_db != null && _ownerId != await _currentOwnerId()) {
      await _db!.close();
      _db = null;
      _ownerId = null;
    }
  }

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
      version: 9,
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
            senderPhone      TEXT,
            senderName       TEXT,
            isForwarded      INTEGER NOT NULL DEFAULT 0,
            isStarred        INTEGER NOT NULL DEFAULT 0,
            isDeletedForMe   INTEGER NOT NULL DEFAULT 0,
            isDeletedForEveryone INTEGER NOT NULL DEFAULT 0,
            isEdited         INTEGER NOT NULL DEFAULT 0
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
            otherUserAvatar      TEXT,
            conversationKind      TEXT NOT NULL DEFAULT '',
            lastReadTime         INTEGER,
            deletedAt            INTEGER,
            deletedBy            TEXT
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_conversations_time
          ON conversations (lastMessageTime DESC)
        ''');

        await _createSuggestedPreviewTables(db);
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
        if (oldVersion < 3) {
          await _addColumnIfMissing(db, 'messages', 'senderPhone', 'TEXT');
        }
        if (oldVersion < 4) {
          await _addColumnIfMissing(db, 'messages', 'senderName', 'TEXT');
        }
        if (oldVersion < 5) {
          await _addColumnIfMissing(
            db,
            'conversations',
            'lastReadTime',
            'INTEGER',
          );
        }
        if (oldVersion < 6) {
          await _addColumnIfMissing(
            db,
            'messages',
            'isEdited',
            'INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 7) {
          await _addColumnIfMissing(
            db,
            'conversations',
            'deletedAt',
            'INTEGER',
          );
          await _addColumnIfMissing(db, 'conversations', 'deletedBy', 'TEXT');
        }
        if (oldVersion < 8) {
          await _addColumnIfMissing(
            db,
            'conversations',
            'conversationKind',
            "TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 9) {
          await _createSuggestedPreviewTables(db);
        }
      },
    );
  }

  Future<String> _currentOwnerId() async {
    final bound = _boundOwnerId?.trim();
    if (bound != null && bound.isNotEmpty) return bound;
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

  static Future<void> _createSuggestedPreviewTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS suggested_preview_sync (
        roomId          TEXT PRIMARY KEY,
        status          TEXT NOT NULL,
        messageCount    INTEGER NOT NULL DEFAULT 0,
        pageCount       INTEGER NOT NULL DEFAULT 0,
        isComplete      INTEGER NOT NULL DEFAULT 0,
        lastFetchedAt   INTEGER NOT NULL,
        lastError       TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS suggested_preview_members (
        roomId          TEXT NOT NULL,
        userId          TEXT NOT NULL,
        membership      TEXT NOT NULL,
        displayName     TEXT,
        avatarUrl       TEXT,
        eventTimestamp  INTEGER NOT NULL,
        PRIMARY KEY (roomId, userId)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_suggested_members_room
      ON suggested_preview_members (roomId, membership)
    ''');
  }

  Future<void> saveSuggestedPreviewSync({
    required String roomId,
    required String status,
    required int messageCount,
    required int pageCount,
    required bool isComplete,
    String? lastError,
  }) async {
    final database = await db;
    await database.insert('suggested_preview_sync', {
      'roomId': roomId,
      'status': status,
      'messageCount': messageCount,
      'pageCount': pageCount,
      'isComplete': isComplete ? 1 : 0,
      'lastFetchedAt': DateTime.now().millisecondsSinceEpoch,
      'lastError': lastError,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> isSuggestedPreviewComplete(String roomId) async {
    final database = await db;
    final rows = await database.query(
      'suggested_preview_sync',
      columns: const ['status', 'isComplete'],
      where: 'roomId = ?',
      whereArgs: [roomId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['status'] == 'complete' &&
        (rows.first['isComplete'] as int? ?? 0) == 1;
  }

  Future<bool> isSuggestedPreviewFresh(
    String roomId, {
    Duration maxAge = const Duration(minutes: 10),
  }) async {
    final database = await db;
    final rows = await database.query(
      'suggested_preview_sync',
      columns: const ['status', 'isComplete', 'lastFetchedAt'],
      where: 'roomId = ?',
      whereArgs: [roomId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    if (row['status'] != 'complete' || (row['isComplete'] as int? ?? 0) != 1) {
      return false;
    }
    final fetchedAt = row['lastFetchedAt'] as int? ?? 0;
    return fetchedAt > 0 &&
        DateTime.now().millisecondsSinceEpoch - fetchedAt <
            maxAge.inMilliseconds;
  }

  Future<void> saveSuggestedPreviewMembers(
    String roomId,
    List<Map<String, dynamic>> members,
  ) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete(
        'suggested_preview_members',
        where: 'roomId = ?',
        whereArgs: [roomId],
      );
      final batch = txn.batch();
      for (final member in members) {
        batch.insert(
          'suggested_preview_members',
          {'roomId': roomId, ...member},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Map<String, dynamic>>> loadSuggestedPreviewMembers(
    String roomId,
  ) async {
    final database = await db;
    final rows = await database.query(
      'suggested_preview_members',
      where: 'roomId = ? AND membership = ?',
      whereArgs: [roomId, 'join'],
      orderBy: 'displayName COLLATE NOCASE, userId',
    );
    return rows
        .map(
          (row) => <String, dynamic>{
            'userId': row['userId'],
            'membership': row['membership'],
            'displayName':
                row['displayName'] == null
                    ? null
                    : _sanitize(row['displayName'] as String),
            'avatarUrl': row['avatarUrl'],
            'eventTimestamp': row['eventTimestamp'],
          },
        )
        .toList();
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
        'senderPhone': m.senderPhone,
        'senderName': m.senderName,
        'isForwarded': m.isForwarded ? 1 : 0,
        'isStarred': m.isStarred ? 1 : 0,
        'isDeletedForMe': m.isDeletedForMe ? 1 : 0,
        'isDeletedForEveryone': m.isDeletedForEveryone ? 1 : 0,
        'isEdited': m.isEdited ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  /// Save a single message — used on optimistic send and on receive.
  Future<void> saveMessage(ChatMessage message) => saveMessages([message]);

  Future<bool> hasMessage(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return false;
    final database = await db;
    final rows = await database.query(
      'messages',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<Set<String>> loadRecentMessageIds({int limit = 1000}) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      columns: ['id'],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows
        .map((row) => row['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

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
        AND (
          id LIKE ? OR id LIKE ? OR id LIKE ? OR id LIKE ? OR id LIKE ?
          OR status = ? OR status = ?
        )
      ''',
      whereArgs: [
        canonical.id,
        canonical.content,
        timestamp - 60000,
        timestamp + 60000,
        'opt_%',
        'Wrytte-%',
        'attach_%',
        'voice_%',
        'video_%',
        MessageStatus.sending.name,
        MessageStatus.failed.name,
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
      senderPhone: row['senderPhone'] as String?,
      senderName: row['senderName'] as String?,
      isForwarded: (row['isForwarded'] as int? ?? 0) == 1,
      isStarred: (row['isStarred'] as int? ?? 0) == 1,
      isDeletedForMe: (row['isDeletedForMe'] as int? ?? 0) == 1,
      isDeletedForEveryone: (row['isDeletedForEveryone'] as int? ?? 0) == 1,
      isEdited: (row['isEdited'] as int? ?? 0) == 1,
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
      final existingKind =
          existing.isNotEmpty
              ? existing.first['conversationKind'] as String?
              : null;
      final normalizedExistingKind = ConversationKind.normalize(existingKind);
      final conversationKind =
          c.hasExplicitKind ? c.conversationKind : normalizedExistingKind;
      final kindChanged =
          c.hasExplicitKind &&
          normalizedExistingKind != ConversationKind.unknown &&
          normalizedExistingKind != c.conversationKind;
      final preservableExistingAvatar = kindChanged ? null : existingAvatar;
      final existingLastReadTime =
          existing.isNotEmpty ? existing.first['lastReadTime'] as int? : null;
      final nextLastReadTime =
          existingLastReadTime ??
          (c.unreadCount == 0
              ? c.lastMessageTime.millisecondsSinceEpoch
              : null);
      final effectiveUnreadCount =
          nextLastReadTime != null &&
                  nextLastReadTime >= c.lastMessageTime.millisecondsSinceEpoch
              ? 0
              : c.unreadCount;

      await database.insert('conversations', {
        'id': c.id,
        'participants': c.participants.join(','),
        'otherUserId': c.otherUserId,
        'lastMessage': c.lastMessage,
        'lastMessageSenderId': c.lastMessageSenderId,
        'lastMessageTime': c.lastMessageTime.millisecondsSinceEpoch,
        'unreadCount': effectiveUnreadCount,
        'lastMessageType': c.lastMessageType,
        'isArchived': c.isArchived ? 1 : 0,
        'isMuted': c.isMuted ? 1 : 0,
        'isPinned': c.isPinned ? 1 : 0,
        // Keep existing cached name/avatar — don't overwrite with null
        'otherUserName': c.otherUserName ?? existingName,
        'otherUserAvatar': c.otherUserAvatar ?? preservableExistingAvatar,
        'conversationKind': conversationKind,
        'lastReadTime': nextLastReadTime,
        'deletedAt': c.deletedAt?.millisecondsSinceEpoch,
        'deletedBy': _encodeStringList(c.deletedBy),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> replaceConversations(
    List<ChatConversation> conversations,
  ) async {
    final database = await db;
    final existingRows = await database.query(
      'conversations',
      columns: [
        'id',
        'lastReadTime',
        'otherUserName',
        'otherUserAvatar',
        'conversationKind',
      ],
    );
    final existingLastReadTimes = <String, int?>{
      for (final row in existingRows)
        row['id'] as String: row['lastReadTime'] as int?,
    };
    final existingNames = <String, String?>{
      for (final row in existingRows)
        row['id'] as String: row['otherUserName'] as String?,
    };
    final existingAvatars = <String, String?>{
      for (final row in existingRows)
        row['id'] as String: row['otherUserAvatar'] as String?,
    };
    final existingKinds = <String, String?>{
      for (final row in existingRows)
        row['id'] as String: row['conversationKind'] as String?,
    };
    await database.transaction((txn) async {
      await txn.delete('conversations');
      for (final c in conversations) {
        final nextLastReadTime =
            existingLastReadTimes[c.id] ??
            (c.unreadCount == 0
                ? c.lastMessageTime.millisecondsSinceEpoch
                : null);
        final effectiveUnreadCount =
            nextLastReadTime != null &&
                    nextLastReadTime >= c.lastMessageTime.millisecondsSinceEpoch
                ? 0
                : c.unreadCount;
        final cleanName = c.otherUserName?.trim() ?? '';
        final cleanAvatar = c.otherUserAvatar?.trim() ?? '';
        final conversationKind =
            c.hasExplicitKind
                ? c.conversationKind
                : ConversationKind.normalize(existingKinds[c.id]);
        final existingKind = ConversationKind.normalize(existingKinds[c.id]);
        final kindChanged =
            c.hasExplicitKind &&
            existingKind != ConversationKind.unknown &&
            existingKind != c.conversationKind;
        await txn.insert('conversations', {
          'id': c.id,
          'participants': c.participants.join(','),
          'otherUserId': c.otherUserId,
          'lastMessage': c.lastMessage,
          'lastMessageSenderId': c.lastMessageSenderId,
          'lastMessageTime': c.lastMessageTime.millisecondsSinceEpoch,
          'unreadCount': effectiveUnreadCount,
          'lastMessageType': c.lastMessageType,
          'isArchived': c.isArchived ? 1 : 0,
          'isMuted': c.isMuted ? 1 : 0,
          'isPinned': c.isPinned ? 1 : 0,
          'otherUserName':
              cleanName.isNotEmpty ? c.otherUserName : existingNames[c.id],
          'otherUserAvatar':
              cleanAvatar.isNotEmpty
                  ? c.otherUserAvatar
                  : kindChanged
                  ? null
                  : existingAvatars[c.id],
          'conversationKind': conversationKind,
          'lastReadTime': nextLastReadTime,
          'deletedAt': c.deletedAt?.millisecondsSinceEpoch,
          'deletedBy': _encodeStringList(c.deletedBy),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Update name + avatar for a conversation after Matrix contact or profile enrichment.
  Future<void> updateConversationUserInfo({
    required String conversationId,
    required String name,
    String? avatar,
    bool clearAvatar = false,
  }) async {
    final database = await db;
    final values = <String, Object?>{'otherUserName': name};
    final cleanAvatar = avatar?.trim() ?? '';
    if (cleanAvatar.isNotEmpty) {
      values['otherUserAvatar'] = cleanAvatar;
    } else if (clearAvatar) {
      values['otherUserAvatar'] = null;
    }
    await database.update(
      'conversations',
      values,
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> deleteConversation(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    final database = await db;
    await database.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> migrateConversationId({
    required String oldConversationId,
    required ChatConversation roomConversation,
  }) async {
    if (oldConversationId.trim().isEmpty ||
        oldConversationId == roomConversation.id) {
      await saveConversations([roomConversation]);
      return;
    }

    final database = await db;
    final existing = await database.query(
      'conversations',
      columns: ['lastReadTime'],
      where: 'id = ?',
      whereArgs: [oldConversationId],
      limit: 1,
    );
    final existingLastReadTime =
        existing.isNotEmpty ? existing.first['lastReadTime'] as int? : null;
    await database.transaction((txn) async {
      await txn.update(
        'messages',
        {'conversationId': roomConversation.id},
        where: 'conversationId = ?',
        whereArgs: [oldConversationId],
      );
      await txn.delete(
        'conversations',
        where: 'id = ?',
        whereArgs: [oldConversationId],
      );
      await txn.insert('conversations', {
        'id': roomConversation.id,
        'participants': roomConversation.participants.join(','),
        'otherUserId': roomConversation.otherUserId,
        'lastMessage': roomConversation.lastMessage,
        'lastMessageSenderId': roomConversation.lastMessageSenderId,
        'lastMessageTime':
            roomConversation.lastMessageTime.millisecondsSinceEpoch,
        'unreadCount': roomConversation.unreadCount,
        'lastMessageType': roomConversation.lastMessageType,
        'isArchived': roomConversation.isArchived ? 1 : 0,
        'isMuted': roomConversation.isMuted ? 1 : 0,
        'isPinned': roomConversation.isPinned ? 1 : 0,
        'otherUserName': roomConversation.otherUserName,
        'otherUserAvatar': roomConversation.otherUserAvatar,
        'conversationKind': roomConversation.conversationKind,
        'lastReadTime': existingLastReadTime,
        'deletedAt': roomConversation.deletedAt?.millisecondsSinceEpoch,
        'deletedBy': _encodeStringList(roomConversation.deletedBy),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
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
    final conversations = rows.map(_rowToConversation).toList();
    final hydrated = await _hydrateConversationPreviewsFromMessages(
      database,
      conversations,
    );
    final rebuilt = await _rebuildConversationsFromCachedMessages(database);
    if (rebuilt.isEmpty) return hydrated;
    if (hydrated.isEmpty) return rebuilt;

    final byId = <String, ChatConversation>{
      for (final conversation in hydrated) conversation.id: conversation,
    };
    for (final conversation in rebuilt) {
      final existing = byId[conversation.id];
      byId[conversation.id] =
          existing == null || existing.lastMessage.trim().isEmpty
              ? conversation.copyWith(
                otherUserName: existing?.otherUserName,
                otherUserAvatar: existing?.otherUserAvatar,
              )
              : existing;
    }
    final merged =
        byId.values.toList()
          ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    return merged;
  }

  /// Load a single conversation row by id, straight from SQLite, with no
  /// message-derived preview repair or group-rebuild logic applied. Used
  /// where we need to know a conversation's actual persisted type (e.g.
  /// whether it's a group) even if it isn't currently loaded in memory —
  /// such as when deciding whether contact enrichment is allowed to touch it.
  Future<ChatConversation?> loadConversation(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return null;
    final database = await db;
    final rows = await database.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToConversation(rows.first);
  }

  Future<List<ChatConversation>> _hydrateConversationPreviewsFromMessages(
    Database database,
    List<ChatConversation> conversations,
  ) async {
    if (conversations.isEmpty) return conversations;

    final hydrated = <ChatConversation>[];
    var changed = false;

    for (final conversation in conversations) {
      if (conversation.deletedAt != null ||
          conversation.lastMessageType == 'group_deleted') {
        hydrated.add(conversation);
        continue;
      }
      final latest = await database.query(
        'messages',
        where: 'conversationId = ? AND isDeletedForMe = ?',
        whereArgs: [conversation.id, 0],
        orderBy: 'timestamp DESC',
        limit: 1,
      );
      if (latest.isEmpty) {
        if (conversation.lastMessage.trim().isEmpty &&
            conversation.lastMessageSenderId.trim().isEmpty) {
          hydrated.add(conversation);
          continue;
        }
        final repaired = conversation.copyWith(
          lastMessage: '',
          lastMessageSenderId: '',
        );
        hydrated.add(repaired);
        changed = true;
        await database.update(
          'conversations',
          {'lastMessage': '', 'lastMessageSenderId': ''},
          where: 'id = ?',
          whereArgs: [conversation.id],
        );
        continue;
      }

      final message = _rowToMessage(latest.first);
      final preserveGroupType = _isStoredGroupConversation(
        conversation.id,
        conversation.otherUserId,
        conversation.participants,
        conversation.lastMessageType,
        conversation.conversationKind,
      );
      final repairedType =
          preserveGroupType
              ? conversation.lastMessageType
              : message.attachmentType ?? conversation.lastMessageType;
      if (conversation.lastMessage == message.content &&
          conversation.lastMessageSenderId == message.senderId &&
          conversation.lastMessageTime == message.timestamp &&
          conversation.lastMessageType == repairedType) {
        hydrated.add(conversation);
        continue;
      }

      final repaired = conversation.copyWith(
        lastMessage: message.content,
        lastMessageSenderId: message.senderId,
        lastMessageTime: message.timestamp,
        lastMessageType: repairedType,
      );
      hydrated.add(repaired);
      changed = true;

      await database.update(
        'conversations',
        {
          'lastMessage': message.content,
          'lastMessageSenderId': message.senderId,
          'lastMessageTime': message.timestamp.millisecondsSinceEpoch,
          'lastMessageType': repairedType,
        },
        where: 'id = ?',
        whereArgs: [conversation.id],
      );
    }

    if (!changed) return conversations;
    hydrated.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    return hydrated;
  }

  Future<List<ChatConversation>> _rebuildConversationsFromCachedMessages(
    Database database,
  ) async {
    final rows = await database.rawQuery('''
      SELECT m.*
      FROM messages m
      INNER JOIN (
        SELECT conversationId, MAX(timestamp) AS maxTimestamp
        FROM messages
        WHERE isDeletedForMe = 0
        GROUP BY conversationId
      ) latest
        ON latest.conversationId = m.conversationId
       AND latest.maxTimestamp = m.timestamp
      WHERE m.isDeletedForMe = 0
      ORDER BY m.timestamp DESC
    ''');
    if (rows.isEmpty) return const [];

    final ownerId = _ownerId ?? await _currentOwnerId();
    final conversations = <ChatConversation>[];
    for (final row in rows) {
      final message = _rowToMessage(row);
      final existingRows = await database.query(
        'conversations',
        columns: [
          'participants',
          'otherUserId',
          'lastReadTime',
          'unreadCount',
          'lastMessageType',
          'otherUserName',
          'otherUserAvatar',
          'conversationKind',
        ],
        where: 'id = ?',
        whereArgs: [message.conversationId],
        limit: 1,
      );
      final existing =
          existingRows.isNotEmpty ? existingRows.first : <String, Object?>{};
      final lastReadTime = existing['lastReadTime'] as int?;
      final existingLastMessageType =
          existing['lastMessageType'] as String? ?? '';
      final existingConversationKind = ConversationKind.normalize(
        existing['conversationKind'] as String?,
      );
      final existingParticipants =
          ((existing['participants'] as String?) ?? '')
              .split(',')
              .where((id) => id.trim().isNotEmpty)
              .toList();
      final existingOtherUserId = existing['otherUserId'] as String? ?? '';
      final storedGroup =
          existingConversationKind == ConversationKind.group ||
          existingConversationKind == ConversationKind.channel ||
          _isStoredGroupConversation(
            message.conversationId,
            existingOtherUserId,
            existingParticipants,
            existingLastMessageType,
            existingConversationKind,
          ) ||
          (message.conversationId.startsWith('!') &&
              _isGroupDeletedPreview(message.content));
      final wasMarkedRead = (existing['unreadCount'] as int? ?? 0) == 0;
      final isAlreadyRead =
          lastReadTime != null
              ? message.timestamp.millisecondsSinceEpoch <= lastReadTime
              : wasMarkedRead;
      final conversation = ChatConversation.fromMessage(
        message,
        ownerId,
      ).copyWith(
        unreadCount: isAlreadyRead ? 0 : null,
        participants:
            existingParticipants.isNotEmpty ? existingParticipants : null,
        otherUserId: storedGroup ? message.conversationId : null,
        lastMessageType:
            storedGroup
                ? _isGroupDeletedPreview(message.content)
                    ? 'group_deleted'
                    : 'group'
                : message.attachmentType,
        otherUserName: existing['otherUserName'] as String?,
        otherUserAvatar: existing['otherUserAvatar'] as String?,
        conversationKind:
            storedGroup
                ? ConversationKind.group
                : existingConversationKind == ConversationKind.direct
                ? ConversationKind.direct
                : null,
      );
      conversations.add(
        await _repairConversationPeerFromMessages(
          database,
          conversation,
          ownerId,
        ),
      );
    }
    await saveConversations(conversations);
    return conversations;
  }

  Future<ChatConversation> _repairConversationPeerFromMessages(
    Database database,
    ChatConversation conversation,
    String ownerId,
  ) async {
    if (_isGroupDeletedPreview(conversation.lastMessage)) {
      return conversation.copyWith(
        otherUserId: conversation.id.startsWith('!') ? conversation.id : null,
        lastMessageType: 'group_deleted',
        conversationKind: ConversationKind.group,
      );
    }
    if (_isStableGroupConversation(conversation)) {
      return conversation;
    }

    final currentPeer = _conversationPeerKey(conversation.otherUserId);
    if (currentPeer.isNotEmpty &&
        currentPeer != _conversationPeerKey(ownerId) &&
        !conversation.otherUserId.startsWith('!')) {
      return conversation;
    }

    final rows = await database.query(
      'messages',
      where: 'conversationId = ? AND isDeletedForMe = ?',
      whereArgs: [conversation.id, 0],
      orderBy: 'timestamp DESC',
    );

    for (final row in rows) {
      final message = _rowToMessage(row);
      final senderKey = _conversationPeerKey(message.senderId);
      final receiverKey = _conversationPeerKey(message.receiverId);
      final ownerKey = _conversationPeerKey(ownerId);
      final senderPhone = _normalizedPhone(message.senderPhone ?? '');
      final senderName = _sanitize(message.senderName ?? '').trim();

      String peer = '';
      String? peerName;
      if (senderKey.isNotEmpty && senderKey != ownerKey) {
        peer = message.senderId;
        peerName = senderName.isNotEmpty ? senderName : senderPhone;
      } else if (receiverKey.isNotEmpty && receiverKey != ownerKey) {
        peer = message.receiverId;
      } else if (senderPhone.isNotEmpty && senderKey != ownerKey) {
        peer = senderPhone;
        peerName = senderName.isNotEmpty ? senderName : senderPhone;
      }

      if (peer.trim().isEmpty || peer.startsWith('!')) continue;
      return conversation.copyWith(
        participants: [ownerId, peer],
        otherUserId: peer,
        otherUserName:
            peerName?.trim().isNotEmpty == true
                ? peerName
                : conversation.otherUserName,
      );
    }

    return conversation;
  }

  bool _isStableGroupConversation(ChatConversation conversation) {
    return _isStoredGroupConversation(
      conversation.id,
      conversation.otherUserId,
      conversation.participants,
      conversation.lastMessageType,
      conversation.conversationKind,
    );
  }

  bool _isStoredGroupConversation(
    String id,
    String otherUserId,
    List<String> participants,
    String lastMessageType, [
    String conversationKind = ConversationKind.unknown,
  ]) {
    final kind = ConversationKind.normalize(conversationKind);
    if (kind == ConversationKind.group || kind == ConversationKind.channel) {
      return true;
    }
    if (kind == ConversationKind.direct) return false;
    if (lastMessageType == 'group' || lastMessageType == 'group_deleted') {
      return true;
    }
    return id.startsWith('!') && otherUserId == id && participants.length > 2;
  }

  bool _isGroupDeletedPreview(String? value) {
    final text = value?.trim().toLowerCase() ?? '';
    return text.startsWith('this group has been deleted');
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
      // Never resolve a group as a direct room, even if the other user
      // is a member of it.
      if (_isStoredGroupConversation(
        conversation.id,
        conversation.otherUserId,
        conversation.participants,
        conversation.lastMessageType,
        conversation.conversationKind,
      )) {
        continue;
      }

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

  Future<List<String>> findConversationIdsByMessageIdentity({
    Iterable<String> userIds = const [],
    Iterable<String> phones = const [],
  }) async {
    final identityKeys = <String>{
      ...userIds.map(_conversationPeerKey),
      ...phones.map(_conversationPeerKey),
    }..removeWhere((key) => key.isEmpty);
    if (identityKeys.isEmpty) return const [];

    final database = await db;
    final rows = await database.query(
      'messages',
      columns: ['conversationId', 'senderId', 'receiverId', 'senderPhone'],
      orderBy: 'timestamp DESC',
    );

    final ids = <String>[];
    for (final row in rows) {
      final senderId = _conversationPeerKey(row['senderId'] as String? ?? '');
      final receiverId = _conversationPeerKey(
        row['receiverId'] as String? ?? '',
      );
      final senderPhone = _conversationPeerKey(
        row['senderPhone'] as String? ?? '',
      );
      final matches =
          identityKeys.contains(senderId) ||
          identityKeys.contains(receiverId) ||
          identityKeys.contains(senderPhone);
      if (!matches) continue;

      final conversationId = row['conversationId'] as String? ?? '';
      if (conversationId.isNotEmpty && !ids.contains(conversationId)) {
        ids.add(conversationId);
      }
    }
    return ids;
  }

  Future<int> materializeContactConversations({
    required String ownerUserId,
    required List<Contact> contacts,
  }) async {
    final owner = _conversationPeerKey(ownerUserId);
    if (owner.isEmpty || contacts.isEmpty) return 0;

    var savedCount = 0;
    for (final contact in contacts) {
      final ids = await findConversationIdsByMessageIdentity(
        userIds: [
          if (contact.wrytteUserId?.trim().isNotEmpty == true)
            contact.wrytteUserId!.trim(),
        ],
        phones: contact.phones,
      );

      for (final conversationId in ids) {
        if (conversationId.trim().startsWith('!')) continue;
        final messages = await loadMessages(conversationId);
        final visible =
            messages.where((message) => !message.isDeletedForMe).toList()
              ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        if (visible.isEmpty) continue;

        final latest = visible.last;
        if (_isGroupDeletedPreview(latest.content)) continue;
        final conversation = await _repairConversationPeerFromMessages(
          await db,
          ChatConversation.fromMessage(latest, ownerUserId).copyWith(
            otherUserName: contact.formattedName,
            otherUserAvatar: contact.avatarUrl,
          ),
          ownerUserId,
        );
        await saveConversations([conversation]);
        savedCount += 1;
      }
    }
    return savedCount;
  }

  ChatConversation _rowToConversation(Map<String, dynamic> row) {
    final participantsRaw = row['participants'] as String? ?? '';
    final participants =
        participantsRaw.isNotEmpty ? participantsRaw.split(',') : <String>[];

    // Sanitize every user-supplied text field to strip lone surrogates
    final rawName = row['otherUserName'] as String?;
    final rawLastMessage = row['lastMessage'] as String;
    final lastMessageTime = row['lastMessageTime'] as int;
    final lastReadTime = row['lastReadTime'] as int?;
    final storedUnreadCount = row['unreadCount'] as int;
    final unreadCount =
        lastReadTime != null && lastReadTime >= lastMessageTime
            ? 0
            : storedUnreadCount;

    return ChatConversation(
      id: row['id'] as String,
      participants: participants,
      otherUserId: row['otherUserId'] as String,
      lastMessage: _sanitize(rawLastMessage),
      lastMessageSenderId: row['lastMessageSenderId'] as String? ?? '',
      lastMessageTime: DateTime.fromMillisecondsSinceEpoch(lastMessageTime),
      unreadCount: unreadCount,
      lastMessageType: row['lastMessageType'] as String? ?? 'text',
      isArchived: (row['isArchived'] as int? ?? 0) == 1,
      isMuted: (row['isMuted'] as int? ?? 0) == 1,
      isPinned: (row['isPinned'] as int? ?? 0) == 1,
      deletedAt: _dateTimeFromMillis(row['deletedAt']),
      deletedBy: _decodeStringList(row['deletedBy']),
      otherUserName: rawName != null ? _sanitize(rawName) : null,
      otherUserAvatar: row['otherUserAvatar'] as String?,
      conversationKind: ConversationKind.normalize(
        row['conversationKind'] as String?,
      ),
    );
  }

  DateTime? _dateTimeFromMillis(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return null;
  }

  String _encodeStringList(List<String> values) => jsonEncode(
    values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(),
  );

  List<String> _decodeStringList(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
      }
    } catch (_) {
      return raw
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return const [];
  }

  // ── Mark conversation as read ──────────────────────────────────────────────

  Future<void> markConversationRead(String conversationId) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      columns: ['timestamp'],
      where: 'conversationId = ? AND isDeletedForMe = ?',
      whereArgs: [conversationId, 0],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    final latestMessageTime =
        rows.isNotEmpty ? rows.first['timestamp'] as int : null;
    final readTime = latestMessageTime ?? DateTime.now().millisecondsSinceEpoch;
    await database.update(
      'conversations',
      {'unreadCount': 0, 'lastReadTime': readTime},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> markConversationReadAt(
    String conversationId,
    DateTime readAt,
  ) async {
    final database = await db;
    await database.update(
      'conversations',
      {'unreadCount': 0, 'lastReadTime': readAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<Map<String, DateTime>> loadConversationReadMarkers() async {
    final database = await db;
    final rows = await database.query(
      'conversations',
      columns: ['id', 'lastReadTime', 'unreadCount', 'lastMessageTime'],
    );
    final markers = <String, DateTime>{};
    for (final row in rows) {
      final id = row['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final lastReadTime = row['lastReadTime'] as int?;
      final unreadCount = row['unreadCount'] as int? ?? 0;
      final lastMessageTime = row['lastMessageTime'] as int? ?? 0;
      final markerTime =
          lastReadTime ?? (unreadCount == 0 ? lastMessageTime : null);
      if (markerTime != null && markerTime > 0) {
        markers[id] = DateTime.fromMillisecondsSinceEpoch(markerTime);
      }
    }
    return markers;
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

  String _normalizedPhone(String value) {
    var cleaned = value.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return '';
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    final digitsOnly = cleaned.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length < 7 || digitsOnly.length > 15) return '';
    return cleaned.startsWith('+') ? cleaned : '+$cleaned';
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

  Future<void> deleteAllLocalDatabases() async {
    final current = _db;
    _db = null;
    _ownerId = null;
    await current?.close();

    final dbPath = await getDatabasesPath();
    final dir = Directory(dbPath);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = basename(entity.path);
      if (!name.startsWith('wrytte_chat_') || !name.endsWith('.db')) continue;
      await deleteDatabase(entity.path);
    }
  }
}
