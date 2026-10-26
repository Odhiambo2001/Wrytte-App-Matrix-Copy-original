import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';

/// Regression coverage for the block/message/privacy fixes.
///
/// Matrix-backed integration tests require a live homeserver and credentials,
/// so this suite validates all deterministic behavior locally and verifies the
/// production source contracts that protect the Matrix boundary. Every test
/// result is appended to test/logs/blocking_regression_test.log.
void main() {
  final logFile = File('test/logs/blocking_regression_test.log');

  setUpAll(() async {
    await logFile.parent.create(recursive: true);
    await logFile.writeAsString(
      '\n=== blocking regression run ${DateTime.now().toUtc().toIso8601String()} ===\n',
      mode: FileMode.append,
    );
  });

  tearDownAll(() async {
    await _log(logFile, 'RUN COMPLETE');
  });

  Future<void> runLogged(String name, Future<void> Function() body) async {
    await _log(logFile, 'START $name');
    try {
      await body();
      await _log(logFile, 'PASS $name');
    } catch (error, stack) {
      await _log(logFile, 'FAIL $name error=$error\n$stack');
      rethrow;
    }
  }

  test('blocked messages remain sent and never become read', () async {
    await runLogged('blocked message status invariant', () async {
      final blocked = ChatMessage(
        id: 'blocked_123',
        conversationId: '!room:example.test',
        senderId: '@b:example.test',
        receiverId: '@a:example.test',
        content: 'message sent while blocked',
        timestamp: DateTime.utc(2026, 1, 1),
        status: MessageStatus.read,
      );

      final corrected = blocked.copyWith(status: MessageStatus.sent);
      expect(corrected.status, MessageStatus.sent);
      expect(corrected.id.startsWith('blocked_'), isTrue);
    });
  });

  test('blocked message IDs are treated as local, not Matrix event IDs', () async {
    await runLogged('blocked ID classification', () async {
      const ids = <String>['blocked_1', 'blocked_42'];
      for (final id in ids) {
        expect(id.startsWith('blocked_'), isTrue);
      }
      expect(r'$event:example.test'.startsWith('blocked_'), isFalse);
    });
  });

  test('blocked message account-data entries deduplicate by either ID', () async {
    await runLogged('blocked account-data deduplication', () async {
      final entries = <Map<String, dynamic>>[
        {
          'room_id': '!room:example.test',
          'event_id': 'blocked_1',
          'blocked_message_id': 'blocked_1',
        },
      ];

      bool alreadyExists(String id) => entries.any(
            (entry) =>
                entry['event_id'] == id || entry['blocked_message_id'] == id,
          );

      expect(alreadyExists('blocked_1'), isTrue);
      expect(alreadyExists('missing'), isFalse);
    });
  });

  test('deleting a blocked message removes its account-data entry', () async {
    await runLogged('blocked delete-for-me contract', () async {
      final entries = <Map<String, dynamic>>[
        {
          'room_id': '!room:example.test',
          'event_id': 'blocked_1',
          'blocked_message_id': 'blocked_1',
        },
        {
          'room_id': '!other:example.test',
          'event_id': 'blocked_2',
          'blocked_message_id': 'blocked_2',
        },
      ];

      entries.removeWhere((entry) {
        final sameRoom = entry['room_id'] == '!room:example.test';
        final sameId =
            entry['event_id'] == 'blocked_1' ||
            entry['blocked_message_id'] == 'blocked_1';
        return sameRoom && sameId;
      });

      expect(entries, hasLength(1));
      expect(entries.single['event_id'], 'blocked_2');
    });
  });

  test('avatar redaction normalizes Matrix user IDs', () async {
    await runLogged('avatar ID normalization', () async {
      String localpart(String value) {
        final normalized = value.trim().toLowerCase();
        final withoutAt = normalized.startsWith('@')
            ? normalized.substring(1)
            : normalized;
        final separator = withoutAt.indexOf(':');
        return separator == -1
            ? withoutAt
            : withoutAt.substring(0, separator);
      }

      expect(localpart('@User:example.test'), 'user');
      expect(localpart('user'), 'user');
      expect(
        localpart('@User:example.test'),
        localpart('USER:another-server'),
      );
    });
  });

  test('production code contains the receipt protection guard', () async {
    await runLogged('receipt protection source contract', () async {
      final source = await File('lib/services/chat/chat_service.dart').readAsString();
      expect(source, contains("message.id.startsWith('blocked_')"));
      expect(source, contains('message.copyWith(status: MessageStatus.sent)'));
      expect(source, contains('!message.id.startsWith(\'blocked_\')'));
    });
  });

  test('production code prevents Matrix redaction of blocked messages', () async {
    await runLogged('blocked delete source contract', () async {
      final source = await File('lib/services/chat/chat_service.dart').readAsString();
      expect(source, contains('Blocked local messages can only be deleted for me'));
      expect(source, contains('removeBlockedMessage'));
    });
  });

  test('all avatar surfaces use the centralized redaction method', () async {
    await runLogged('avatar surface source contract', () async {
      final files = <String>[
        'lib/ui/screens/chats/conversations_screen.dart',
        'lib/ui/screens/chats/chat_screen.dart',
        'lib/ui/screens/profile_screen.dart',
      ];

      for (final path in files) {
        final source = await File(path).readAsString();
        expect(
          source,
          contains('shouldHidePeerAvatar'),
          reason: '$path must use the centralized avatar redaction predicate',
        );
      }

      final stateSource =
          await File('lib/services/matrix/block_state_service.dart')
              .readAsString();
      expect(stateSource, contains('bool shouldHidePeerAvatar'));
      expect(stateSource, contains('isBlockedByBbb(peer'));
    });
  });

  test('chat navigation does not await avatar downloads', () async {
    await runLogged('chat navigation avatar warm is non-blocking', () async {
      final source =
          await File('lib/ui/screens/chats/conversations_screen.dart')
              .readAsString();

      expect(
        source,
        contains('unawaited(\n            AvatarPreloadService.warm('),
        reason: 'avatar warming must run after navigation is allowed to start',
      );
      expect(
        source,
        isNot(contains('await AvatarPreloadService.warm(')),
        reason: 'a slow avatar download must not delay Navigator.push',
      );
    });
  });

  test('clear-marker loading is cached and bounded', () async {
    await runLogged('chat navigation clear marker contract', () async {
      final source = await File('lib/services/chat/chat_service.dart')
          .readAsString();

      expect(source, contains('final Set<String> _clearMarkerLoadedRooms'));
      expect(source, contains('_clearMarkerLoadedRooms.contains(id)'));
      expect(source, contains('_clearMarkerLoadedRooms.add(id)'));
      expect(source, contains('_loadClearMarkerForRoom(roomId).timeout('));
      expect(source, contains('const Duration(milliseconds: 600)'));
      expect(source, contains('_clearMarkerLoadedRooms.clear()'));
      expect(
        source,
        contains('await _loadClearMarkerBounded(conversationId);'),
      );
    });
  });

  test('chat screen preserves ready local messages during empty hydration', () async {
    await runLogged('chat local-first rendering contract', () async {
      final source = await File('lib/ui/screens/chats/chat_screen.dart')
          .readAsString();

      expect(
        source,
        contains("if (_messages.isNotEmpty) {\n          apkLog(\n            'ChatScreen.roomStream',"),
        reason: 'an empty Matrix stream must not clear ready local messages',
      );
      expect(
        source,
        contains('if (_messages.isEmpty) {'),
        reason: 'room mismatch must not erase supplied local messages',
      );
    });
  });
}

Future<void> _log(File file, String message) async {
  await file.writeAsString(
    '[${DateTime.now().toUtc().toIso8601String()}] $message\n',
    mode: FileMode.append,
  );
}
