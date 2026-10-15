// lib/ui/screens/chats/chat_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:url_launcher/url_launcher.dart';

import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/attachment_local_store.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrixrtc_livekit_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/calls/livekit_call_screen.dart';
import 'package:wrytte/ui/screens/chats/video_message_recorder_screen.dart';
import 'package:wrytte/ui/screens/chats/widgets/message_bubble.dart';

import 'package:wrytte/data/repositories/camera_repository_impl.dart';
import 'package:wrytte/data/services/camera_capabilities_service.dart';
import 'package:wrytte/data/services/camera_session_manager.dart';
import 'package:wrytte/data/services/device_camera_service.dart';
import 'package:wrytte/ui/chat/widgets/chat_composer.dart';
import 'package:wrytte/domain/repositories/audio_recording_repository.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/domain/repositories/attachment_picker_repository.dart';
import 'package:wrytte/data/repositories/media_library_repository_impl.dart';
import 'package:wrytte/data/repositories/attachment_picker_repository_impl.dart';
import 'package:wrytte/data/services/device_media_library_service.dart';
import 'package:wrytte/data/services/device_attachment_picker_service.dart';
import 'package:wrytte/domain/models/attachment_gallery_config.dart';
import 'package:wrytte/domain/models/attachment_gallery_result.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/ui/camera/widgets/attachment_camera_preview.dart';
import 'package:wrytte/ui/camera/views/wrytte_camera_route.dart';
import 'package:wrytte/ui/media/views/attachment_gallery_sheet.dart';
import 'package:wrytte/ui/screens/chats/widgets/source_composer_audio_repository.dart';
import 'package:wrytte/ui/chat/view_models/chat_view_model.dart'; // ChatRecordMode
import 'package:wrytte/ui/chat/widgets/chat_layout_metrics.dart';
import 'package:wrytte/domain/models/voice_recording_result.dart';
import 'package:wrytte/domain/models/camera_capture_result.dart';

import 'package:wrytte/ui/screens/chats/widgets/message_input.dart';
import 'package:wrytte/ui/widgets/pinned_events_strip.dart';
import 'package:wrytte/ui/screens/group_profile_screen.dart';
import 'package:wrytte/ui/screens/profile_screen.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:wrytte/utils/country_phone_number.dart';
import 'package:wrytte/utils/wrytte_id.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/chat/widgets/image_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/contact_message_bubble.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String receiverId;
  final String currentUserId;
  final String title;
  final String? avatarUrl;
  final List<ChatMessage> initialMessages;
  final bool readOnlyUntilJoin;
  final int? initialMemberCount;
  final bool initialMemberCountIsAuthoritative;
  final String? groupAlias;
  final String? groupDescription;
  final String conversationKind;
  final int? initialRoomProfileVersion;
  final bool loadRoomEventsOnDemand;
  final bool initialEventsHaveMore;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.receiverId,
    required this.currentUserId,
    required this.title,
    this.avatarUrl,
    this.initialMessages = const [],
    this.readOnlyUntilJoin = false,
    this.initialMemberCount,
    this.initialMemberCountIsAuthoritative = false,
    this.groupAlias,
    this.groupDescription,
    this.conversationKind = ConversationKind.unknown,
    this.initialRoomProfileVersion,
    this.loadRoomEventsOnDemand = false,
    this.initialEventsHaveMore = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScrollBehavior extends ScrollBehavior {
  const _ChatScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _ForwardTarget {
  final String? conversationId;
  final String receiverId;
  final String title;
  final String? subtitle;
  final String? avatarUrl;
  final String? phone;
  final bool isSavedContact;
  final int sortOrder;

  const _ForwardTarget({
    this.conversationId,
    required this.receiverId,
    required this.title,
    this.subtitle,
    this.avatarUrl,
    this.phone,
    this.isSavedContact = false,
    this.sortOrder = 0,
  });

  _ForwardTarget copyWith({
    String? conversationId,
    String? receiverId,
    String? subtitle,
    String? avatarUrl,
    int? sortOrder,
  }) {
    return _ForwardTarget(
      conversationId: conversationId ?? this.conversationId,
      receiverId: receiverId ?? this.receiverId,
      title: title,
      subtitle: subtitle ?? this.subtitle,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      phone: phone,
      isSavedContact: isSavedContact,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class _ForwardPickerPage extends StatefulWidget {
  final List<_ForwardTarget> targets;
  final String previewText;
  final String? previewAvatarUrl;

  const _ForwardPickerPage({
    required this.targets,
    required this.previewText,
    this.previewAvatarUrl,
  });

  @override
  State<_ForwardPickerPage> createState() => _ForwardPickerPageState();
}

class _ForwardPickerPageState extends State<_ForwardPickerPage> {
  final Set<String> _selectedReceiverIds = {};

  List<_ForwardTarget> get _selectedTargets =>
      widget.targets
          .where((target) => _selectedReceiverIds.contains(target.receiverId))
          .toList();

  void _toggle(_ForwardTarget target) {
    setState(() {
      if (!_selectedReceiverIds.add(target.receiverId)) {
        _selectedReceiverIds.remove(target.receiverId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final savedTargets =
        widget.targets.where((target) => target.isSavedContact).toList();
    final recentTargets =
        widget.targets.where((target) => !target.isSavedContact).toList();
    final selectedTargets = _selectedTargets;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF08090B),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Forward to...',
              style: TextStyle(color: Colors.white, fontSize: 22),
            ),
            if (selectedTargets.isNotEmpty)
              Text(
                '${selectedTargets.length} selected',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 13,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add_outlined, color: Colors.white),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            onPressed: () {},
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                children: [
                  if (savedTargets.isNotEmpty) ...[
                    _sectionHeader('Frequently contacted'),
                    for (final target in savedTargets) _targetTile(target),
                  ],
                  if (recentTargets.isNotEmpty) ...[
                    _sectionHeader('Recent chats'),
                    for (final target in recentTargets) _targetTile(target),
                  ],
                ],
              ),
            ),
            if (selectedTargets.isNotEmpty) _bottomBar(selectedTargets),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.48),
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _targetTile(_ForwardTarget target) {
    final selected = _selectedReceiverIds.contains(target.receiverId);
    final subtitle = target.subtitle?.trim() ?? '';

    return InkWell(
      onTap: () => _toggle(target),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          children: [
            UserAvatar(
              imageUrl: target.avatarUrl,
              cacheIdentity: 'user:${target.receiverId.trim().toLowerCase()}',
              name: target.title,
              size: 54,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.48),
                        fontSize: 15,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF20C768) : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      selected
                          ? const Color(0xFF20C768)
                          : Colors.white.withValues(alpha: 0.42),
                  width: 2,
                ),
              ),
              child:
                  selected
                      ? const Icon(Icons.check, color: Colors.black, size: 19)
                      : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(List<_ForwardTarget> selectedTargets) {
    final names = selectedTargets.map((target) => target.title).join(', ');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101318),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              width: 54,
              height: 54,
              color: const Color(0xFF1B2028),
              child:
                  widget.previewAvatarUrl?.isNotEmpty == true
                      ? Image.network(
                        widget.previewAvatarUrl!,
                        fit: BoxFit.cover,
                      )
                      : const Icon(
                        Icons.chat_bubble_outline,
                        color: Colors.white54,
                      ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.previewText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.56),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  names,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FloatingActionButton(
            heroTag: 'forward-send',
            mini: false,
            backgroundColor: const Color(0xFF20C768),
            foregroundColor: Colors.black,
            onPressed: () => Navigator.pop(context, selectedTargets),
            child: const Icon(Icons.send, size: 28),
          ),
        ],
      ),
    );
  }
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();

  final ChatService _chat = ChatService();

  StreamSubscription<List<ChatMessage>>? _messagesSub;
  String? _messagesSubscriptionConversationId;
  String? _lastRoomStreamFingerprint;
  StreamSubscription<mx.SyncUpdate>? _roomProfileSyncSub;
  StreamSubscription<String>? _groupContactsChangedSub;
  StreamSubscription<String>? _profileUpdatesSub;

  final List<ChatMessage> _messages = [];
  final List<ChatMessage> _initialStreamBuffer = [];
  final Map<String, String> _optimisticIdByContent = {};
  final Map<String, String> _groupMemberNames = {};
  final Map<String, String> _groupMemberAvatars = {};
  final Set<String> _groupSenderProfilesInFlight = {};
  final Set<String> _pendingGroupMemberProfileRefreshes = {};
  final Set<String> _pinUpdatesInFlight = {};
  final Map<String, DateTime> _lastPinUpdateAt = {};
  final Map<String, GlobalKey> _messageKeys = {};
  String? _latestPinActivityNotice;
  String? _pinActivityAnchorEventId;
  List<String> _pinnedEventIds = [];
  List<String> _pinnedForMeEventIds = [];
  List<mx.User> _groupMembers = const [];

  List<String> get _visiblePinnedEventIds => <String>[
    ..._pinnedForMeEventIds,
    ..._pinnedEventIds.where((id) => !_pinnedForMeEventIds.contains(id)),
  ];

  String? _resolvedConversationId;

  bool _loadingOlder = false;
  bool _loadingInitial = true;
  bool _hasMoreOlder = true;
  bool _groupProfilesReady = false;

  bool _isSending = false;
  bool _matrixAvailable = false;
  bool _joinedSuggestedGroup = false;
  bool _joiningSuggestedGroup = false;

  UserProfile? _receiverProfile;
  ContactIdentity? _receiverIdentity;
  bool _receiverIsSavedContact = false;
  bool _receiverOnline = false;
  ChatMessage? _replyingTo;
  ChatMessage? _editingMessage;
  double? _stableStatusBarH;
  String? _stableHeaderAvatarUrl;
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  Timer? _typingHeartbeatTimer;
  Timer? _typingStopTimer;
  bool _typingAnnounced = false;
  bool _someoneElseTyping = false;
  bool? _lastLoggedTypingState;
  Set<String> _typingUserIds = {};
  DateTime? _peerLastActiveAt;

  // ── debug overlay ──────────────────────────────────────────────────────────
  bool _showDebug = false;
  final ScrollController _debugScrollCtrl = ScrollController();
  final ApkDebugLogger _logger = ApkDebugLogger.instance;

  static const double _kHeaderPillH = 48.0;
  static const double _kInputPillH = 40.0;


  ChatRecordMode _recordMode = ChatRecordMode.audio;

  void _toggleRecordMode() {
    setState(() {
      _recordMode = _recordMode == ChatRecordMode.audio
          ? ChatRecordMode.video
          : ChatRecordMode.audio;
    });
  }

  Future<void> _openAttachments() async {
    if (_isDeletedConversation) return;
    // ChatScreen owns the composer providers below its build subtree, so the
    // State's context cannot read them here. Create the attachment repositories
    // at the point where the attachment route is opened instead.
    final media = MediaLibraryRepositoryImpl(DeviceMediaLibraryService());
    final camera = CameraRepositoryImpl(
      DeviceCameraService(),
      const CameraCapabilitiesService(),
      CameraSessionManager(),
    );
    final picker = AttachmentPickerRepositoryImpl(
      DeviceAttachmentPickerService(),
    );
    final cameraOpen = ValueNotifier<bool>(false);
    final resultFuture = showWrytteAttachmentGallery(
      context,
      config: const AttachmentGalleryConfig(
        purpose: AttachmentPurpose.chat,
        maxSelectionCount: 30,
      ),
      repository: media,
      pickerRepository: picker,
      cameraPreviewBuilder: (_) => AttachmentCameraPreview(
        repository: camera,
        fullScreenCameraOpen: cameraOpen,
      ),
      onCameraRequested: (origin, latestAsset) async {
        cameraOpen.value = true;
        try {
          return await showWrytteCamera(
            context,
            repository: camera,
            config: const CameraSessionConfig.chatAttachment(),
            origin: origin,
            returnToGallery: true,
            keepSessionAliveOnExit: true,
          );
        } finally {
          cameraOpen.value = false;
        }
      },
    );
    unawaited(camera.open(const CameraSessionConfig.chatAttachment()));
    AttachmentGalleryResult? result;
    try {
      result = await resultFuture;
    } finally {
      await camera.close();
      cameraOpen.dispose();
    }
    if (!mounted || result == null) return;
    await _handleAttachmentGalleryResult(result, media);
  }

  Future<void> _handleAttachmentGalleryResult(
    AttachmentGalleryResult result,
    MediaLibraryRepository media,
  ) async {
    if (result.locationLabel case final location?) {
      final text = location.trim();
      if (text.isNotEmpty) {
        final previousText = _controller.text;
        _controller.text = text;
        try {
          await _send();
        } finally {
          if (mounted && _controller.text.isEmpty) {
            _controller.text = previousText;
          }
        }
      }
    }
    if (result.preparedFilePath case final path?) {
      await _sendPickedAttachment(path, 'image', caption: result.caption);
    }
    for (final asset in result.assets) {
      final path = await media.loadFilePath(asset.id);
      if (path != null) {
        await _sendPickedAttachment(path, asset.kind.name, caption: result.caption);
      }
    }
    for (final file in result.files) {
      await _sendPickedAttachment(file.path, 'file', caption: result.caption);
    }
    for (final contact in result.contacts) {
      await _sendContactAttachment(
        name: contact.displayName,
        phone: contact.phoneNumber,
      );
    }
    if (result.cameraCapture case final capture?) {
      await _sendPickedAttachment(
        capture.path,
        capture.type == CameraMediaType.video ? 'video' : 'image',
        caption: result.caption,
      );
    }
  }

  Future<void> _sendContactAttachment({
    required String name,
    required String phone,
  }) async {
    final cleanName = name.trim().isEmpty ? 'Contact' : name.trim();
    final cleanPhone = phone.trim();
    if (cleanPhone.isEmpty) return;

    final previousText = _controller.text;
    _controller.text = '[wrytte-contact]\n$cleanName\n$cleanPhone';
    try {
      await _send();
    } finally {
      if (mounted && _controller.text.isEmpty) {
        _controller.text = previousText;
      }
    }
  }

  // ─── LIFECYCLE ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _chat.activateConversationRead(widget.conversationId);
    _receiverOnline = _currentPeerPresenceIsOnline();
    if (!_isGroupChat) {
      final peerId = _profilePeerId();
      if (peerId != null && peerId.isNotEmpty) {
        apkLog(
          'Matrix.presence',
          'chat_peer_initial user_id="$peerId" '
              'status="${_receiverOnline ? 'online' : 'offline'}" '
              'last_seen_at="${_peerLastActiveAt?.toLocal().toIso8601String() ?? 'unknown'}"',
        );
      }
    }
    _stableHeaderAvatarUrl = _initialStableHeaderAvatarUrl();
    _subscribeToRoomProfileUpdates();
    _subscribeToGroupContactUpdates();
    _profileUpdatesSub = UserProfileService.instance.publicProfileUpdateStream
        .listen(_onPublicProfileUpdated);
    apkLog(
      'ChatScreen',
      '── initState ──  '
          'convId="${widget.conversationId}"  '
          'receiverId="${widget.receiverId}"  '
          'currentUserId="${widget.currentUserId}"',
    );
    if (!_isGroupChat) {
      apkLog(
        'Identity.display',
        'surface="conversation_header" phase="initial" '
            'user_id="${_matrixLocalpart(widget.receiverId)}" '
            'name="${widget.title}" avatar=${(_stableHeaderAvatarUrl ?? '').trim().isNotEmpty} '
            'avatar_url="${_stableHeaderAvatarUrl ?? ''}"',
      );
    }
    if (_isSelfConversation) {
      _logSelfConversationBlocked('open');
    }
    final initialGroupRoom = MatrixChatService.instance.getRoomById(
      widget.conversationId,
    );
    _joinedSuggestedGroup =
        !widget.readOnlyUntilJoin ||
        initialGroupRoom?.membership == mx.Membership.join;

    _seedGroupProfile2FromMemory();
    _logger.addListener(_onNewLog);
    if (widget.initialMessages.isNotEmpty && _suppliedRoomMatchesScreenKind) {
      _mergeMessages(widget.initialMessages);
      _loadingInitial = false;
    }
    _hasMoreOlder = widget.initialEventsHaveMore;
    _focusNode.addListener(_onInputFocusChanged);
    _controller.addListener(_onComposerChanged);
    _loadInitial();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stableStatusBarH ??= MediaQuery.viewPaddingOf(context).top;
  }

  @override
  void dispose() {
    _chat.deactivateConversationRead(widget.conversationId);
    _roomProfileSyncSub?.cancel();
    _groupContactsChangedSub?.cancel();
    _profileUpdatesSub?.cancel();
    final resolvedConversationId = _resolvedConversationId;
    if (resolvedConversationId != null &&
        resolvedConversationId != widget.conversationId) {
      _chat.deactivateConversationRead(resolvedConversationId);
    }
    _logger.removeListener(_onNewLog);
    _messagesSub?.cancel();
    _highlightTimer?.cancel();
    _typingHeartbeatTimer?.cancel();
    _typingStopTimer?.cancel();
    unawaited(_sendTyping(false));
    _controller.removeListener(_onComposerChanged);
    _controller.dispose();
    _focusNode.removeListener(_onInputFocusChanged);
    _scrollCtrl.dispose();
    _debugScrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _subscribeToRoomProfileUpdates() {
    _roomProfileSyncSub = MatrixChatService.instance.syncStream.listen((
      update,
    ) {
      if (!mounted) return;
      _applyPeerPresenceUpdate(update);
      final room = MatrixChatService.instance.getRoomById(
        _resolvedConversationId ?? widget.conversationId,
      );
      if (room == null) return;
      final currentUserId = MatrixClientService.instance.userId;
      final typingUserIds =
          room.typingUsers
              .where((user) => user.id != currentUserId)
              .map((user) => user.id)
              .toSet();
      final typingUsersChanged =
          typingUserIds.length != _typingUserIds.length ||
          !typingUserIds.containsAll(_typingUserIds);
      final isSomeoneTyping = typingUserIds.isNotEmpty;
      if (typingUsersChanged) {
        _typingUserIds = typingUserIds;
        apkLog(
          'Matrix.typing',
          'received room_id="${room.id}" typing=$isSomeoneTyping '
              'users="${typingUserIds.join(',')}"',
        );
      }
      if (isSomeoneTyping != _someoneElseTyping) {
        setState(() => _someoneElseTyping = isSomeoneTyping);
      }
      if (_pinUpdatesInFlight.isEmpty) {
        final pinned = room.pinnedEventIds.toList();
        final pinnedForMe =
            _isGroupChat
                ? const <String>[]
                : _chat.pinnedForMeEventIdsForRoom(room.id);
        if (!listEquals(pinned, _pinnedEventIds) ||
            !listEquals(pinnedForMe, _pinnedForMeEventIds)) {
          setState(() {
            _pinnedEventIds = pinned;
            _pinnedForMeEventIds = pinnedForMe;
          });
        }
      }
      if (!_isGroupChat) {
        return;
      }
      final latestAvatar = _safeGroupRoomAvatarUrl(room);
      if (latestAvatar == _stableHeaderAvatarUrl) {
        // Name/topic/custom profile state may still have changed.
        setState(() {});
        return;
      }
      setState(() => _stableHeaderAvatarUrl = latestAvatar);
    });
  }

  bool _currentPeerPresenceIsOnline() {
    if (_isGroupChat || !MatrixClientService.instance.isInitialized) {
      return false;
    }
    final peerId = _profilePeerId();
    if (peerId == null || peerId.trim().isEmpty) return false;
    if (!_hasLocalPeerRoom(peerId)) return false;
    final peerLocalpart = _matrixLocalpart(peerId).toLowerCase();
    final client = MatrixClientService.instance.client;
    _peerLastActiveAt =
        MatrixClientService.instance.lastSeenAtFor(peerId) ?? _peerLastActiveAt;
    // The deprecated map is the local sync cache. fetchCurrentPresence would
    // make the on-demand presence request this screen intentionally avoids.
    // ignore: deprecated_member_use
    for (final entry in client.presences.entries) {
      if (_matrixLocalpart(entry.key).toLowerCase() != peerLocalpart) continue;
      // A sparse offline presence event may replace the SDK cache entry while
      // omitting last_active_ago. Keep the last real timestamp observed from
      // the server instead of erasing it.
      _peerLastActiveAt =
          entry.value.lastActiveTimestamp ??
          MatrixClientService.instance.lastSeenAtFor(peerId) ??
          _peerLastActiveAt;
      return entry.value.presence == mx.PresenceType.online;
    }
    return false;
  }

  Future<void> _refreshPeerPresence() async {
    if (_isGroupChat || !MatrixClientService.instance.isInitialized) return;
    final peerId = _profilePeerId();
    if (peerId == null || peerId.trim().isEmpty) return;
    try {
      final presence = await MatrixClientService.instance.client
          .fetchCurrentPresence(peerId);
      if (!mounted) return;
      setState(() {
        _receiverOnline = presence.presence == mx.PresenceType.online;
        _peerLastActiveAt =
            presence.lastActiveTimestamp ?? _peerLastActiveAt;
      });
      apkLog(
        'Matrix.presence',
        'chat_peer_fetched user_id="$peerId" '
            'status="${_receiverOnline ? 'online' : 'offline'}" '
            'last_seen_at="${_peerLastActiveAt?.toLocal().toIso8601String() ?? 'unknown'}"',
      );
    } catch (error) {
      apkLog('Matrix.presence', 'fetch failed user_id="$peerId" error=$error');
    }
  }

  void _applyPeerPresenceUpdate(mx.SyncUpdate update) {
    if (_isGroupChat) return;
    final peerId = _profilePeerId();
    if (peerId == null || peerId.trim().isEmpty) return;
    if (!_hasLocalPeerRoom(peerId)) return;
    final peerLocalpart = _matrixLocalpart(peerId).toLowerCase();
    for (final presence in update.presence ?? const []) {
      if (_matrixLocalpart(presence.senderId).toLowerCase() != peerLocalpart) {
        continue;
      }
      final isOnline = presence.presence.presence == mx.PresenceType.online;
      final lastActiveAgo = presence.presence.lastActiveAgo;
      DateTime? cachedLastActiveAt = _peerLastActiveAt;
      // Some offline presence updates omit last_active_ago. Preserve the most
      // recent timestamp already in the SDK cache instead of dropping it and
      // rendering a bare "Offline" label.
      // ignore: deprecated_member_use
      for (final entry
          in MatrixClientService.instance.client.presences.entries) {
        if (_matrixLocalpart(entry.key).toLowerCase() != peerLocalpart) {
          continue;
        }
        cachedLastActiveAt =
            entry.value.lastActiveTimestamp ??
            MatrixClientService.instance.lastSeenAtFor(peerId) ??
            cachedLastActiveAt;
        break;
      }
      cachedLastActiveAt ??= MatrixClientService.instance.lastSeenAtFor(peerId);
      final lastActiveAt =
          lastActiveAgo == null
              ? cachedLastActiveAt
              : DateTime.now().subtract(Duration(milliseconds: lastActiveAgo));
      if (isOnline == _receiverOnline && lastActiveAt == _peerLastActiveAt) {
        continue;
      }
      setState(() {
        _receiverOnline = isOnline;
        _peerLastActiveAt = lastActiveAt;
      });
      apkLog(
        'Matrix.presence',
        'chat_peer_status user_id="$peerId" '
            'status="${isOnline ? 'online' : 'offline'}" '
            'last_seen_at="${lastActiveAt?.toLocal().toIso8601String() ?? 'unknown'}" '
            'last_active_ago_ms="${lastActiveAgo ?? 'unknown'}"',
      );
    }
  }

  bool _hasLocalPeerRoom(String peerId) {
    final room = MatrixChatService.instance.getRoomById(
      _resolvedConversationId ?? widget.conversationId,
    );
    if (room == null || room.membership != mx.Membership.join) return false;
    final peerLocalpart = _matrixLocalpart(peerId).toLowerCase();
    return room.getParticipants().any(
      (member) => _matrixLocalpart(member.id).toLowerCase() == peerLocalpart,
    );
  }

  void _onPublicProfileUpdated(String userId) {
    if (!mounted) return;
    final changed = _matrixLocalpart(userId).toLowerCase();
    if (changed.isEmpty) return;
    if (changed == _matrixLocalpart(widget.currentUserId).toLowerCase()) {
      return;
    }
    if (_isGroupChat) {
      if (!_groupMembers.any(
        (member) => _matrixLocalpart(member.id).toLowerCase() == changed,
      )) {
        return;
      }
      _groupMemberNames.removeWhere(
        (key, _) => _matrixLocalpart(key).toLowerCase() == changed,
      );
      _groupMemberAvatars.removeWhere(
        (key, _) => _matrixLocalpart(key).toLowerCase() == changed,
      );
      _pendingGroupMemberProfileRefreshes.add(userId);
      unawaited(_loadGroupMemberProfileName(userId, forceRefresh: true));
      return;
    }
    final peer = _profilePeerId();
    if (peer != null && _matrixLocalpart(peer).toLowerCase() == changed) {
      unawaited(_loadReceiverProfile(forceRefresh: true));
    }
  }

  void _subscribeToGroupContactUpdates() {
    if (!_isGroupChat) return;
    _groupContactsChangedSub = ContactService.contactsChanged.listen((owner) {
      if (!mounted ||
          owner.trim().toLowerCase() !=
              widget.currentUserId.trim().toLowerCase()) {
        return;
      }
      _groupMemberNames.clear();
      _groupMemberAvatars.clear();
      _seedGroupProfile2FromMemory();
      _resolveGroupMessageSenders(_messages);
      _groupProfilesReady = false;
      if (mounted) setState(() {});
      unawaited(_refreshGroupContactProfiles());
    });
  }

  Future<void> _refreshGroupContactProfiles() async {
    await _primeGroupMemberProfiles(_activeConversationId);
    if (!mounted) return;
    setState(() => _groupProfilesReady = true);
  }

  void _onInputFocusChanged() {
    if (!_focusNode.hasFocus) {
      _scheduleTypingStop();
    } else if (_controller.text.trim().isNotEmpty) {
      _onComposerChanged();
    }
    if (mounted) setState(() {});
  }

  void _onComposerChanged() {
    if (_controller.text.trim().isEmpty || !_focusNode.hasFocus) {
      _scheduleTypingStop();
      return;
    }
    _typingStopTimer?.cancel();
    if (!_typingAnnounced) {
      _typingAnnounced = true;
      unawaited(_sendTyping(true));
    }
    _typingHeartbeatTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_sendTyping(true)),
    );
  }

  void _scheduleTypingStop() {
    _typingHeartbeatTimer?.cancel();
    _typingHeartbeatTimer = null;
    if (!_typingAnnounced) return;
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 2), () {
      _typingAnnounced = false;
      unawaited(_sendTyping(false));
    });
  }

  Future<void> _sendTyping(bool isTyping) async {
    final roomId = (_resolvedConversationId ?? widget.conversationId).trim();
    if (roomId.isEmpty) return;
    _chat.updateLocalTypingState(roomId, isTyping);
    if (!MatrixClientService.instance.isInitialized) return;
    final room = MatrixChatService.instance.getRoomById(roomId);
    if (room == null || room.membership != mx.Membership.join) return;
    try {
      await room.setTyping(isTyping, timeout: isTyping ? 4000 : null);
      if (_lastLoggedTypingState != isTyping) {
        _lastLoggedTypingState = isTyping;
        apkLog(
          'Matrix.typing',
          'sent room_id="$roomId" typing=$isTyping '
              'timeout_ms=${isTyping ? 4000 : 'none'}',
        );
      }
    } catch (error) {
      apkLog(
        'Matrix.typing',
        'send failed room_id="$roomId" typing=$isTyping error=$error',
      );
    }
  }

  String _peerPresenceLabel() {
    if (_receiverOnline) return 'Online';
    final lastActiveAt = _peerLastActiveAt;
    if (lastActiveAt == null) return 'Last seen';
    final localLastActive = lastActiveAt.toLocal();
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(localLastActive));
    final date = MaterialLocalizations.of(
      context,
    ).formatShortDate(localLastActive);
    return 'Last seen $date at $time';
  }

  void _onNewLog() {
    if (_showDebug && mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_debugScrollCtrl.hasClients) {
          _debugScrollCtrl.jumpTo(_debugScrollCtrl.position.maxScrollExtent);
        }
      });
    }
  }

  // ─── RESOLVE CONVERSATION ID ───────────────────────────────────────────────

  String _normaliseId(String id) => id.trim();

  bool get _isSelfConversation {
    final self = _matrixLocalpart(widget.currentUserId);
    final receiver = _matrixLocalpart(widget.receiverId);
    return self.isNotEmpty && receiver.isNotEmpty && self == receiver;
  }

  void _logSelfConversationBlocked(String action) {
    apkLog(
      'ChatScreen.self',
      '$action blocked: receiver is current user '
          'current="${_matrixLocalpart(widget.currentUserId)}" '
          'receiver="${_matrixLocalpart(widget.receiverId)}"',
    );
  }

  void _showSelfConversationError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This contact is linked to your own account.'),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  bool _looksLikePhone(String value) {
    final stripped = value.trim().replaceAll(RegExp(r'[\s\-()+]'), '');
    if (stripped.length < 7 || stripped.length > 15) return false;
    return stripped.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(stripped);
  }

  String _extractPhone(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return '';
    final match = RegExp(r'(\+?\d[\d\s\-()]{6,}\d)').firstMatch(raw);
    if (match == null) return '';
    final phone = match.group(1)?.trim() ?? '';
    return _looksLikePhone(phone) ? phone : '';
  }

  String _phoneFromIdentifier(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || _looksLikeMatrixId(raw)) return '';

    final extracted = _extractPhone(value);
    if (extracted.isNotEmpty) return extracted;

    final localpart = _matrixLocalpart(raw);
    if (_looksLikeMatrixId(localpart)) return '';
    final digits = localpart.replaceAll(RegExp(r'[^\d]'), '');
    return RegExp(r'^\+?\d{7,15}$').hasMatch(localpart) ? digits : '';
  }

  bool _looksLikeMatrixId(String value) {
    final trimmed = value.trim();
    final localpart = _matrixLocalpart(trimmed);
    return trimmed.startsWith('@') ||
        trimmed.startsWith('!') ||
        trimmed.contains(':matrix.') ||
        RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart);
  }

  String _formatPhone(String phone) {
    final wrytteId = WrytteId.forDisplay(phone);
    if (wrytteId != null) return wrytteId;
    return CountryPhoneNumber.formatInternationalDisplay(phone);
  }

  String _firstPhoneFrom(Iterable<String?> candidates) {
    for (final candidate in candidates) {
      final phone = _phoneFromIdentifier(candidate);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }
    return '';
  }

  Future<String> _resolveConversationId() async {
    if (_resolvedConversationId != null) return _resolvedConversationId!;

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    apkLog(
      'ChatScreen._resolveConv',
      'raw="${widget.receiverId}"  '
          'normalised="$normalisedReceiverId"  '
          'passedConvId="${widget.conversationId}"',
    );

    final suppliedRoomIsAllowed =
        widget.conversationId.startsWith('!') && _suppliedRoomMatchesScreenKind;
    if (suppliedRoomIsAllowed) {
      _resolvedConversationId = widget.conversationId;
      _chat.activateConversationRead(widget.conversationId);
      apkLog(
        'ChatScreen._resolveConv',
        'used passedConvId → "$_resolvedConversationId"',
      );
      return _resolvedConversationId!;
    }

    if (!_matrixAvailable) {
      apkLog(
        'ChatScreen._resolveConv',
        'Matrix unavailable; using local convId "${widget.conversationId}"',
      );
      return widget.conversationId;
    }

    final matrixConversationId = await _chat.findMatrixConversationId(
      normalisedReceiverId,
    );
    if (matrixConversationId == null) {
      apkLog(
        'ChatScreen._resolveConv',
        'Matrix direct room unavailable; using local convId "${widget.conversationId}"',
      );
      return widget.conversationId;
    }

    _resolvedConversationId = matrixConversationId;
    _chat.activateConversationRead(matrixConversationId);
    apkLog(
      'ChatScreen._resolveConv',
      'Matrix direct room -> "$_resolvedConversationId"',
    );

    return _resolvedConversationId!;
  }

  Future<String?> _resolveMatrixConversationIdForSend() async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('resolve/send room');
      return null;
    }

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final suppliedRoomIsAllowed =
        widget.conversationId.startsWith('!') && _suppliedRoomMatchesScreenKind;
    if (suppliedRoomIsAllowed) {
      _resolvedConversationId = widget.conversationId;
      _chat.activateConversationRead(widget.conversationId);
      return widget.conversationId;
    }

    try {
      apkLog('ChatScreen._resolveSendConv', 'validating Matrix before send...');
      await _chat.connect();
      _matrixAvailable = true;
    } catch (e) {
      _matrixAvailable = false;
      apkLog('ChatScreen._resolveSendConv', 'Matrix connect failed: $e');
      return null;
    }

    final matrixConversationId = await _chat.getMatrixConversationId(
      normalisedReceiverId,
    );
    if (matrixConversationId == null) {
      apkLog(
        'ChatScreen._resolveSendConv',
        'failed to create/reuse Matrix direct room',
      );
      return null;
    }
    _resolvedConversationId = matrixConversationId;
    _chat.activateConversationRead(matrixConversationId);
    return matrixConversationId;
  }

  // ─── INIT ──────────────────────────────────────────────────────────────────

  Future<void> _loadInitial() async {
    _matrixAvailable = false;
    _hasMoreOlder = widget.initialEventsHaveMore;
    if (_suppliedRoomMatchesScreenKind && !widget.loadRoomEventsOnDemand) {
      await _hydrateAndSubscribe(widget.conversationId);
    }

    apkLog('ChatScreen._loadInitial', 'calling chat.connect()…');

    try {
      await _chat.connect();
      _matrixAvailable = true;
      _resolvedConversationId = null;
    } catch (e) {
      _matrixAvailable = false;
      apkLog('ChatScreen._loadInitial', ' connect() FAILED: $e');
      if (mounted) {
        setState(() => _loadingInitial = false);
      }
      return; // Matrix unavailable; keep the chat usable with local messages.
    }

    apkLog(
      'ChatScreen._loadInitial',
      'connect() done  isConnected=${_chat.isConnected}',
    ); // use actual flag

    final realConvId = await _resolveConversationId();
    _chat.activateConversationRead(realConvId);
    await _refreshPeerPresence();
    _pinnedEventIds = _chat.pinnedEventIdsForRoom(realConvId);
    _pinnedForMeEventIds =
        _isGroupChat
            ? <String>[]
            : _chat.pinnedForMeEventIdsForRoom(realConvId);
    apkLog('ChatScreen._loadInitial', 'realConvId="$realConvId"');
    if (realConvId != widget.conversationId) {
      if (widget.conversationId.startsWith('!')) {
        // A different Matrix room can never be migrated into this one. In
        // particular, never move group history into a newly resolved DM.
        if (!mounted) return;
        setState(() => _messages.clear());
      } else {
        await _migrateLocalConversationToRoom(realConvId, const []);
        if (!mounted) return;
        setState(() => _normaliseMessagesToConversation(realConvId));
      }
    }

    if (realConvId.startsWith('!') &&
        !_isReadOnlySuggestedGroup &&
        !widget.loadRoomEventsOnDemand) {
      final restored = await _chat.fetchMessageHistory(
        conversationID: realConvId,
      );
      if (restored.isNotEmpty) {
        _replaceMessagesFromSharedCache(restored);
      }
    }

    await _loadReceiverProfile(publish: false);

    if (_isKnownGroupConversationId(realConvId) || _isGroupChat) {
      await _primeGroupMemberProfiles(realConvId);
    }

    await _chat.markConversationAsRead(realConvId);
    await NotificationService.instance.clearConversationNotifications(
      realConvId,
    );
    if (realConvId != widget.conversationId) {
      await NotificationService.instance.clearConversationNotifications(
        widget.conversationId,
      );
    }

    if (!mounted) return;
    setState(() {
      _mergeMessages(_initialStreamBuffer);
      _initialStreamBuffer.clear();
      _groupProfilesReady = true;
      _loadingInitial = false;
    });

    if (!widget.loadRoomEventsOnDemand) {
      await _hydrateAndSubscribe(realConvId, publishHydrated: false);
    }
  }

  bool get _suppliedRoomMatchesScreenKind {
    if (!widget.conversationId.startsWith('!')) return true;
    if (widget.conversationKind != ConversationKind.direct) return true;
    final room = MatrixChatService.instance.getRoomById(widget.conversationId);
    if (room != null) {
      return _chat.isVerifiedDirectConversation(
        widget.conversationId,
        widget.receiverId,
      );
    }
    if (_cachedConversationIsGroup(widget.conversationId)) return false;
    // The screen kind comes from the account-scoped persisted conversation
    // row. A Matrix client may remain "logged in" while the device is offline,
    // even though no live room state is available to verify the DM again.
    // Requiring that transient verification made a cached timeline disappear
    // after closing and reopening the same chat.
    return true;
  }

  Future<void> _hydrateAndSubscribe(
    String convId, {
    bool publishHydrated = true,
  }) async {
    final msgs = await _chat.hydrateConversation(convId);
    apkLog(
      'ChatScreen._hydrateAndSubscribe',
      'hydrated ${msgs.length} msgs for "$convId"',
    );
    if (mounted && (msgs.isNotEmpty || _messages.isEmpty)) {
      if (!publishHydrated || _loadingInitial) {
        _replaceMessagesFromSharedCache(msgs);
      } else {
        setState(() => _replaceMessagesFromSharedCache(msgs));
        if (_receiverProfile == null && _receiverIdentity == null) {
          unawaited(_loadReceiverProfile(forceRefresh: false));
        }
      }
    }

    if (_messagesSub != null && _messagesSubscriptionConversationId == convId) {
      return;
    }
    await _messagesSub?.cancel();
    _messagesSubscriptionConversationId = convId;
    _lastRoomStreamFingerprint = null;
    _messagesSub = _chat.messagesStreamFor(convId).listen((messages) {
      if (!mounted) return;
      final fingerprint = _messageSnapshotFingerprint(messages);
      if (_lastRoomStreamFingerprint == fingerprint) return;
      _lastRoomStreamFingerprint = fingerprint;
      apkLog('ChatScreen.roomStream', 'room="$convId" msgs=${messages.length}');
      if (messages.isEmpty &&
          _messages.isNotEmpty &&
          !_chat.isConversationDeleted(convId)) {
        return;
      }
      if (_loadingInitial) {
        _initialStreamBuffer
          ..clear()
          ..addAll(messages);
        return;
      }
      setState(() => _replaceMessagesFromSharedCache(messages));
      final currentConv = _resolvedConversationId ?? widget.conversationId;
      if (convId == currentConv && messages.any((m) => !_isMine(m))) {
        unawaited(_chat.markConversationAsRead(convId));
        unawaited(
          NotificationService.instance.clearConversationNotifications(convId),
        );
      }
    });
  }

  String _messageSnapshotFingerprint(List<ChatMessage> messages) {
    return messages
        .map(
          (message) =>
              '${message.id}:${message.status.name}:${message.isEdited}:'
              '${message.isDeletedForMe}:${message.isDeletedForEveryone}:'
              '${message.content.hashCode}:${message.attachmentUrl?.hashCode}',
        )
        .join('|');
  }

  Future<void> _migrateLocalConversationToRoom(
    String roomId,
    List<ChatMessage> roomCached,
  ) async {
    if (roomId == widget.conversationId) return;
    final combined = <ChatMessage>[..._messages, ...roomCached]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final latest =
        combined.isNotEmpty
            ? combined.last
            : ChatMessage(
              id: 'empty_$roomId',
              conversationId: roomId,
              senderId: '',
              receiverId: widget.receiverId,
              content: '',
              timestamp: DateTime.now(),
              status: MessageStatus.sent,
            );
    final roomConversation = ChatConversation.fromMessage(
      latest.copyWith(conversationId: roomId),
      widget.currentUserId,
    ).copyWith(
      otherUserName: widget.title,
      otherUserAvatar: widget.avatarUrl,
      conversationKind:
          _isGroupChat ? ConversationKind.group : ConversationKind.direct,
      otherUserId: _isGroupChat ? roomId : null,
      lastMessageType: _isGroupChat ? 'group' : null,
    );

    await ChatLocalDb.instance.migrateConversationId(
      oldConversationId: widget.conversationId,
      roomConversation: roomConversation,
    );
    apkLog(
      'ChatScreen._loadInitial',
      'migrated local conversation "${widget.conversationId}" -> "$roomId"',
    );
  }

  Future<void> _loadReceiverProfile({
    bool publish = true,
    bool forceRefresh = false,
  }) async {
    // A group has no receiver profile. Its identity is the room ID and its
    // avatar may only come from the room's m.room.avatar state event. Looking
    // through message peers here can otherwise select a member as "receiver".
    if (_isGroupChat) return;
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    final profileUid = _profilePeerId();
    if (profileUid == null) return;
    final fallbackPhone = _firstPhoneFrom([profileUid, widget.title]);
    final profile = await UserProfileService.instance.getProfileByUid(
      profileUid,
      phone: fallbackPhone,
      forceRefresh: forceRefresh,
    );

    final matrixProfile =
        profile?.moduleProfileLoaded == true
            ? null
            : await _loadMatrixProfile(profileUid);
    final saved =
        ownerUserId == null || ownerUserId.isEmpty
            ? null
            : await _findSavedContact(
              ownerUserId,
              profileUid,
              phone: fallbackPhone,
            );
    var identity =
        ownerUserId == null || ownerUserId.isEmpty
            ? null
            : await ContactIdentityCache.instance.findByMatrixId(
              ownerUserId: ownerUserId,
              matrixUserId: profileUid,
            );

    final hasCachedSavedName =
        _cleanDisplayName(identity?.savedName).isNotEmpty;
    if (ownerUserId != null &&
        ownerUserId.isNotEmpty &&
        saved == null &&
        !hasCachedSavedName) {
      await ContactIdentityCache.instance.clearSavedName(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
      );
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
      );
    }

    if (ownerUserId != null && ownerUserId.isNotEmpty) {
      if (saved != null && profile != null) {
        final nextAvatar =
            profile.moduleProfileLoaded
                ? (profile.hasProfileImage ? profile.profileImage : null)
                : profile.hasProfileImage
                ? profile.profileImage
                : matrixProfile?.$2 ?? widget.avatarUrl;
        if (nextAvatar?.trim().isNotEmpty == true &&
            nextAvatar?.trim() != widget.avatarUrl?.trim()) {
          unawaited(
            AvatarPreloadService.replace(
              oldUrl: widget.avatarUrl,
              newUrl: nextAvatar,
            ),
          );
        }
        final refreshedContact =
            await ContactLocalDb.refreshPublicProfileFields(
              ownerUserId: ownerUserId,
              wrytteUserId: profileUid,
              phone: profile.phone.isNotEmpty ? profile.phone : fallbackPhone,
              avatarUrl:
                  profile.moduleProfileLoaded ? (nextAvatar ?? '') : nextAvatar,
              bio: profile.bio,
            );
        if (refreshedContact != null) {
          await ChatService().applySavedContact(refreshedContact);
        }
      }
      await ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
        phone: profile?.phone ?? fallbackPhone,
        profileName:
            _cleanDisplayName(profile?.displayName).isNotEmpty
                ? profile?.displayName
                : matrixProfile?.$1,
        savedName: saved?.formattedName,
        avatarUrl:
            profile?.moduleProfileLoaded == true
                ? (profile!.hasProfileImage ? profile.profileImage : '')
                : profile?.hasProfileImage == true
                ? profile!.profileImage
                : matrixProfile?.$2 ?? widget.avatarUrl,
        bio: profile?.bio,
        clearAvatar:
            profile?.moduleProfileLoaded == true &&
            profile?.hasProfileImage != true,
        clearBio: profile?.moduleProfileLoaded == true,
      );
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
      );
    }

    final nextAvatar =
        profile?.moduleProfileLoaded == true
            ? (profile!.hasProfileImage ? profile.profileImage : null)
            : profile?.hasProfileImage == true
            ? profile!.profileImage
            : identity?.avatarUrl ?? widget.avatarUrl;
    await AvatarPreloadService.warm(
      nextAvatar,
      cacheIdentity: 'user:${profileUid.trim().toLowerCase()}',
    );

    apkLog(
      'Identity.display',
      'surface="conversation_header" phase="resolved" '
          'user_id="${_matrixLocalpart(profileUid)}" saved=${saved != null} '
          'profile="${saved != null ? 'profile2' : 'profile1'}" '
          'name_source="${saved != null ? 'saved_contact' : 'phone'}" '
          'name="${saved?.formattedName ?? _formatPhone(profile?.phone ?? fallbackPhone)}" '
          'phone="${profile?.phone ?? fallbackPhone}" '
          'avatar=${(nextAvatar ?? '').trim().isNotEmpty} avatar_url="${nextAvatar ?? ''}" '
          'bio=${profile?.bio.trim().isNotEmpty == true}',
    );

    if (!mounted) return;
    if (publish) {
      setState(() {
        _receiverProfile = profile;
        _receiverIdentity = identity;
        _receiverIsSavedContact = saved != null;
        _stableHeaderAvatarUrl = _safePersonHeaderAvatar(nextAvatar);
      });
    } else {
      _receiverProfile = profile;
      _receiverIdentity = identity;
      _receiverIsSavedContact = saved != null;
    }
    await _persistResolvedReceiverInfo();
  }

  String? _profilePeerId() {
    if (_isGroupChat) return null;
    final room = MatrixChatService.instance.getRoomById(_activeConversationId);
    final directPeer = room?.directChatMatrixID?.trim();

    for (final candidate in [
      _receiverIdentity?.matrixUserId,
      widget.receiverId,
      directPeer,
      ..._messagePeerIdentifiers(),
      ..._roomPeerIdentifiers(),
    ]) {
      final value = candidate?.trim() ?? '';
      if (value.isEmpty) continue;
      if (value.startsWith('!') || value.startsWith('@!')) continue;
      if (_matrixLocalpart(value) == _matrixLocalpart(widget.currentUserId)) {
        continue;
      }
      if (_isValidMatrixUserId(value) || _looksLikeMatrixId(value)) {
        return value;
      }
    }
    return null;
  }

  Future<Contact?> _findSavedContact(
    String ownerUserId,
    String uid, {
    String? phone,
  }) async {
    final targetLocalpart = _matrixLocalpart(uid);
    String normalizedPhone(String? value) {
      final parsed = _phoneFromIdentifier(value);
      if (parsed.isEmpty) return '';
      return _formatPhone(parsed).replaceAll(RegExp(r'[^\d]'), '');
    }

    final targetPhone = normalizedPhone(phone);
    final contacts = await ContactService().getMatrixContactsCached(
      ownerUserId,
    );
    for (final contact in contacts) {
      final contactId = contact.wrytteUserId;
      final sameWrytteId =
          contactId != null &&
          contactId.isNotEmpty &&
          _matrixLocalpart(contactId) == targetLocalpart;
      final samePhone =
          targetPhone.isNotEmpty &&
          contact.phones.map(normalizedPhone).contains(targetPhone);
      if (sameWrytteId || samePhone) return contact;
    }
    return null;
  }

  Future<(String?, String?)?> _loadMatrixProfile(String uid) async {
    try {
      final profile = await UserProfileService.instance.getProfileByUid(uid);
      if (profile == null) return null;
      if (profile.moduleProfileLoaded) {
        return (
          profile.displayName.isEmpty ? null : profile.displayName,
          profile.hasProfileImage ? profile.profileImage : null,
        );
      }
      return (
        profile.name,
        profile.hasProfileImage ? profile.profileImage : null,
      );
    } catch (_) {
      return null;
    }
  }

  String get _resolvedHeaderName {
    if (_isGroupChat) {
      final room = MatrixChatService.instance.getRoomById(
        _activeConversationId,
      );
      for (final candidate in [room?.name, widget.title]) {
        final groupName = _cleanDisplayName(candidate);
        if (groupName.isNotEmpty && !groupName.startsWith('gr.@')) {
          return groupName;
        }
      }
      return 'Group';
    }

    final savedName = _cleanDisplayName(_receiverIdentity?.savedName);
    if (savedName.isNotEmpty) return savedName;

    final initialSavedName = _cleanDisplayName(widget.title);
    if (initialSavedName.isNotEmpty) return initialSavedName;

    for (final candidate in [
      _profilePeerId(),
      _receiverIdentity?.matrixUserId,
      _receiverIdentity?.phone,
      _receiverIdentity?.profileName,
      _receiverProfile?.uid,
      _receiverProfile?.phone,
      widget.receiverId,
      widget.title,
    ]) {
      final wrytteId = WrytteId.forDisplay(candidate ?? '');
      if (wrytteId != null) return wrytteId;
    }

    final phone = _firstPhoneFrom([
      _receiverIdentity?.phone,
      _receiverProfile?.phone,
      widget.receiverId,
      widget.title,
      ..._messagePeerIdentifiers(),
      ..._roomPeerIdentifiers(),
    ]);
    return phone.isNotEmpty ? _formatPhone(phone) : '';
  }

  Future<void> _persistResolvedReceiverInfo() async {
    final name = _resolvedHeaderName.trim();
    final avatar =
        _isGroupChat
            ? _safeGroupRoomAvatarUrl(
              MatrixChatService.instance.getRoomById(_activeConversationId),
            )
            : _receiverProfile?.hasProfileImage == true
            ? _receiverProfile!.profileImage
            : _receiverIdentity?.avatarUrl ?? widget.avatarUrl;
    if (name.isEmpty && (avatar ?? '').trim().isEmpty) return;
    try {
      await ChatLocalDb.instance.updateConversationUserInfo(
        conversationId: _resolvedConversationId ?? widget.conversationId,
        name: name,
        avatar: avatar,
      );
    } catch (e) {
      debugPrint('[ChatScreen] receiver info persist skipped: $e');
    }
  }

  Iterable<String> _messagePeerIdentifiers() sync* {
    for (final message in _messages.reversed) {
      if (_isMine(message)) {
        yield message.receiverId;
      } else {
        yield message.senderId;
      }
    }
  }

  Iterable<String> _roomPeerIdentifiers() sync* {
    final room = MatrixChatService.instance.getRoomById(_activeConversationId);
    if (room == null) return;
    final currentLocalpart = _matrixLocalpart(widget.currentUserId);
    for (final member in room.getParticipants(_groupMemberships)) {
      final id = member.id.trim();
      if (id.isEmpty || id.startsWith('!') || id.startsWith('@!')) continue;
      if (_matrixLocalpart(id) == currentLocalpart) continue;
      yield id;
    }
  }

  String _cleanDisplayName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty ||
        _looksLikePhone(trimmed) ||
        WrytteId.forDisplay(trimmed) != null) {
      return '';
    }
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return '';
    }
    if (trimmed.startsWith('@') && trimmed.contains(':')) return '';
    if (trimmed.startsWith('!') && trimmed.contains(':')) return '';
    if (RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(trimmed)) {
      return '';
    }
    return trimmed;
  }

  // ─── PAGINATION ────────────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.maxScrollExtent <= 0) return;
    final nearOldest =
        _scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 80;
    if (nearOldest && !_loadingOlder && _hasMoreOlder) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    if (!widget.loadRoomEventsOnDemand) return;
    setState(() => _loadingOlder = true);
    try {
      final page = await _chat.fetchProfileRoomEventPage(
        roomId: _resolvedConversationId ?? widget.conversationId,
        limit: 15,
      );
      if (!mounted) return;
      setState(() {
        _mergeMessages(page.messages);
        _hasMoreOlder = page.hasMore;
        _loadingOlder = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingOlder = false);
      apkLog('ChatScreen.historyPage', 'older page failed: $error');
    }
  }

  // ─── SEND TEXT ─────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    apkLog(
      'ChatScreen._send',
      'text="${text.length > 40 ? text.substring(0, 40) : text}"  '
          'isSending=$_isSending  '
          'textEmpty=${text.isEmpty}',
    );

    if (text.isEmpty || _isSending) return;
    if (_isDeletedConversation) return;
    final editing = _editingMessage;
    if (editing != null) {
      await _sendEditedMessage(editing, text);
      return;
    }
    if (_isSelfConversation) {
      _logSelfConversationBlocked('send');
      _showSelfConversationError();
      return;
    }

    _controller.clear();
    final reply = _replyingTo;
    setState(() {
      _isSending = true;
      _replyingTo = null;
      _editingMessage = null;
    });

    final normalisedReceiverId = _normaliseId(widget.receiverId);

    final optimistic = ChatMessage(
      id: 'opt_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: _resolvedConversationId ?? widget.conversationId,
      senderId: widget.currentUserId,
      receiverId: normalisedReceiverId,
      content: text,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      replyToMessageId: reply?.id,
      replyToSenderId: _replySenderIdForOutgoingReply(reply),
      replyPreview: reply == null ? null : _replyPreviewForMessage(reply),
    );

    setState(() => _messages.add(optimistic));
    _optimisticIdByContent['${normalisedReceiverId}_$text'] = optimistic.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());

    final realConvId = await _resolveMatrixConversationIdForSend();

    apkLog(
      'ChatScreen._send',
      'realConvId="$realConvId"  '
          'normalisedReceiver="$normalisedReceiverId"',
    );

    final outbound = optimistic.copyWith(
      conversationId: realConvId ?? optimistic.conversationId,
    );

    if (!_matrixAvailable || realConvId == null) {
      final local = outbound.copyWith(status: MessageStatus.failed);
      await _saveLocalMessage(local);
      if (mounted) {
        setState(() {
          _replaceOptimisticMessage(optimistic.id, local);
        });
      }
      if (mounted) setState(() => _isSending = false);
      return;
    }

    try {
      apkLog('ChatScreen._send', 'calling chat.sendMessage…');
      final sent = await _chat.sendMessage(outbound);
      apkLog('ChatScreen._send', ' sent  id=${sent.id}  status=${sent.status}');

      await _saveCanonicalSentMessage(sent);
      if (mounted) {
        setState(() => _replaceOptimisticMessage(optimistic.id, sent));
      }
    } catch (e) {
      apkLog('ChatScreen._send', ' SEND FAILED: $e');
      final local = outbound.copyWith(status: MessageStatus.failed);
      await _saveLocalMessage(local);
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == optimistic.id);
          if (idx != -1) {
            _messages[idx] = local;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendEditedMessage(ChatMessage message, String text) async {
    if (text.trim() == message.content.trim()) {
      _controller.clear();
      setState(() => _editingMessage = null);
      return;
    }
    if (_isSending) return;

    _controller.clear();
    setState(() {
      _isSending = true;
      _editingMessage = null;
    });

    final optimistic = message.copyWith(
      content: text.trim(),
      status: MessageStatus.sending,
      isEdited: true,
    );
    setState(() => _replaceOptimisticMessage(message.id, optimistic));

    try {
      final updated = await _chat.editMessage(
        message: message,
        newContent: text,
      );
      if (mounted) {
        setState(() => _replaceOptimisticMessage(message.id, updated));
      }
    } catch (e) {
      apkLog('ChatScreen._sendEditedMessage', 'EDIT FAILED: $e');
      if (mounted) {
        setState(() => _replaceOptimisticMessage(message.id, message));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Edit failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ─── SEND VOICE ────────────────────────────────────────────────────────────

  Future<void> _saveLocalMessage(ChatMessage message) async {
    await ChatLocalDb.instance.saveMessage(message);
    await ChatLocalDb.instance.saveConversations([
      ChatConversation.fromMessage(message, widget.currentUserId).copyWith(
        otherUserName: widget.title,
        otherUserAvatar: _isGroupChat ? null : widget.avatarUrl,
        conversationKind:
            _isGroupChat ? ConversationKind.group : ConversationKind.direct,
        otherUserId: _isGroupChat ? message.conversationId : null,
        lastMessageType: _isGroupChat ? 'group' : null,
      ),
    ]);
  }

  Future<void> _saveCanonicalSentMessage(ChatMessage message) async {
    await ChatLocalDb.instance.deleteDuplicateOutgoingEchoesFor(message);
    await _saveLocalMessage(message);
  }

  Future<void> _sendVoiceNote(String filePath, int durationSeconds) async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('send voice note');
      _showSelfConversationError();
      return;
    }
    if (_isDeletedConversation) return;

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final realConvId = await _resolveMatrixConversationIdForSend();
    apkLog(
      'ChatScreen._sendVoice',
      'duration=${durationSeconds}s  receiver="$normalisedReceiverId"',
    );

    if (realConvId == null) {
      apkLog('ChatScreen._sendVoice', 'Matrix room unavailable');
      return;
    }

    final placeholderId = 'voice_${DateTime.now().millisecondsSinceEpoch}';
    final placeholder = ChatMessage(
      id: placeholderId,
      conversationId: realConvId,
      senderId: widget.currentUserId,
      receiverId: normalisedReceiverId,
      content: '',
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentUrl: filePath,
      attachmentType: 'voice',
      voiceDuration: durationSeconds,
    );

    setState(() => _messages.add(placeholder));
    _optimisticIdByContent['${normalisedReceiverId}_${placeholder.content}_$filePath'] =
        placeholder.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());

    try {
      await _chat.sendVoiceMessage(
        receiverID: normalisedReceiverId,
        filePath: filePath,
        durationSeconds: durationSeconds,
        conversationId: realConvId,
      );
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
      }
    } catch (e) {
      apkLog('ChatScreen._sendVoice', ' ERROR: $e');
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send voice note: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _recordAndSendVideoMessage() async {
    if (_isDeletedConversation) return;
    final result = await Navigator.of(context).push<VideoMessageResult>(
      MaterialPageRoute(
        builder:
            (_) => const VideoMessageRecorderScreen(
              maxDuration: Duration(seconds: 60),
            ),
      ),
    );
    if (!mounted || result == null) return;
    await _sendVideoNote(result.filePath, result.durationSeconds);
  }

  Future<void> _sendVideoNote(String filePath, int durationSeconds) async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('send video note');
      _showSelfConversationError();
      return;
    }
    if (_isDeletedConversation) return;

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final realConvId = await _resolveMatrixConversationIdForSend();
    apkLog(
      'ChatScreen._sendVideo',
      'duration=${durationSeconds}s  receiver="$normalisedReceiverId"',
    );

    if (realConvId == null) {
      apkLog('ChatScreen._sendVideo', 'Matrix room unavailable');
      return;
    }

    final placeholderId = 'video_${DateTime.now().millisecondsSinceEpoch}';
    final placeholder = ChatMessage(
      id: placeholderId,
      conversationId: realConvId,
      senderId: widget.currentUserId,
      receiverId: normalisedReceiverId,
      content: 'Video message',
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentUrl: filePath,
      attachmentType: 'video',
      voiceDuration: durationSeconds,
    );

    setState(() => _messages.add(placeholder));
    _optimisticIdByContent['${normalisedReceiverId}_${placeholder.content}_$filePath'] =
        placeholder.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());

    try {
      await _chat.sendVideoMessage(
        receiverID: normalisedReceiverId,
        filePath: filePath,
        durationSeconds: durationSeconds,
        conversationId: realConvId,
      );
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
      }
    } catch (e) {
      apkLog('ChatScreen._sendVideo', ' ERROR: $e');
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send video message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _pickCameraAttachment() async {
    if (_isDeletedConversation) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 92,
    );
    if (!mounted || picked == null) return;
    await _sendPickedAttachment(picked.path, 'image');
  }

  Future<void> _pickGalleryAttachment() async {
    if (_isDeletedConversation) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF111318),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                _messageActionTile(
                  icon: Icons.image_outlined,
                  label: 'Photo',
                  onTap: () => Navigator.pop(context, 'image'),
                ),
                _messageActionTile(
                  icon: Icons.videocam_outlined,
                  label: 'Video',
                  onTap: () => Navigator.pop(context, 'video'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
    );
    if (!mounted || choice == null) return;

    final picker = ImagePicker();
    final picked =
        choice == 'video'
            ? await picker.pickVideo(source: ImageSource.gallery)
            : await picker.pickImage(
              source: ImageSource.gallery,
              imageQuality: 92,
            );
    if (!mounted || picked == null) return;
    await _sendPickedAttachment(picked.path, choice);
  }

  Future<void> _pickFileAttachment() async {
    if (_isDeletedConversation) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
      );
      if (!mounted || result == null || result.files.isEmpty) return;

      final path = result.files.single.path?.trim() ?? '';
      if (path.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not access the selected file'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
      await _sendPickedAttachment(path, 'file');
    } catch (error) {
      apkLog('ChatScreen._pickFileAttachment', 'ERROR: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not select file: $error'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _sendPickedAttachment(
    String filePath,
    String type, {
    String? caption,
  }) async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('send attachment');
      _showSelfConversationError();
      return;
    }
    if (_isDeletedConversation) return;
    if (!await File(filePath).exists()) return;

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final realConvId = await _resolveMatrixConversationIdForSend();
    if (realConvId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not send attachment: room unavailable'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    try {
      await _chat.validateAttachmentUpload(
        filePath: filePath,
        attachmentType: type,
      );
      await _chat.removeFailedAttachmentAttempts(
        conversationId: realConvId,
        filePath: filePath,
      );
    } catch (e) {
      await _chat.removeFailedAttachmentAttempts(
        conversationId: realConvId,
        filePath: filePath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot send attachment: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final placeholderId = 'attach_${DateTime.now().millisecondsSinceEpoch}';
    final placeholder = ChatMessage(
      id: placeholderId,
      conversationId: realConvId,
      senderId: widget.currentUserId,
      receiverId: normalisedReceiverId,
      content: caption?.trim().isNotEmpty == true
          ? caption!.trim()
          : _attachmentLabelForType(type),
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentUrl: filePath,
      attachmentType: type,
    );

    setState(() => _messages.add(placeholder));
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());

    try {
      final sent = await _chat.sendAttachmentMessage(
        receiverID: normalisedReceiverId,
        filePath: filePath,
        attachmentType: type,
        conversationId: realConvId,
        caption: caption,
      );
      await _saveCanonicalSentMessage(sent);
      if (mounted) {
        setState(() => _replaceOptimisticMessage(placeholderId, sent));
      }
    } catch (e) {
      apkLog('ChatScreen._sendAttachment', 'ERROR: $e');
      if (mounted) {
        setState(() {
          _messages.removeWhere((message) => message.id == placeholderId);
          _optimisticIdByContent.removeWhere((_, id) => id == placeholderId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send attachment: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ─── CALL ──────────────────────────────────────────────────────────────────

  Future<void> _startCall(CallType type) async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('start call');
      _showSelfConversationError();
      return;
    }

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final displayName = widget.title;

    try {
      final liveKitCall = await MatrixRtcLiveKitService.instance
          .startDirectOutgoing(receiverId: normalisedReceiverId, type: type);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => LiveKitCallScreen(call: liveKitCall, title: displayName),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not start call: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ─── SCROLL ────────────────────────────────────────────────────────────────

  bool get _shouldLiftShortConversation {
    return _messages.isNotEmpty && _messages.length <= 4;
  }

  void _jumpToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(0);
  }

  // ─── MESSAGE HELPERS ───────────────────────────────────────────────────────

  void _mergeMessages(List<ChatMessage> incoming) {
    for (final msg in incoming) {
      _upsertMessage(msg);
    }
    _removeDuplicateOutgoingEchoes();
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _resolveGroupMessageSenders(incoming);
  }

  void _replaceMessagesFromSharedCache(List<ChatMessage> incoming) {
    final optimistic = _messages.where(_isLocalOutgoingEcho).toList();
    _messages
      ..clear()
      ..addAll(incoming)
      ..addAll(
        optimistic.where(
          (candidate) =>
              !incoming.any((m) => _isDuplicateOutgoingEcho(candidate, m)),
        ),
      );
    _removeDuplicateOutgoingEchoes();
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _resolveGroupMessageSenders(incoming);
  }

  void _resolveGroupMessageSenders(Iterable<ChatMessage> messages) {
    if (!_isGroupChat) return;
    final senders = <String, ChatMessage>{};
    for (final message in messages) {
      final senderId = message.senderId.trim();
      if (senderId.isEmpty || senderId.startsWith('!') || _isMine(message)) {
        continue;
      }
      senders.putIfAbsent(senderId, () => message);
      final localpart = _matrixLocalpart(senderId);
      final savedName = _cleanDisplayName(_groupMemberNames[localpart]);
      final savedAvatar = _groupMemberAvatars[localpart]?.trim() ?? '';
      if (savedName.isNotEmpty) _groupMemberNames[senderId] = savedName;
      if (savedAvatar.isNotEmpty) _groupMemberAvatars[senderId] = savedAvatar;
      final eventName = _cleanDisplayName(message.senderName);
      if (eventName.isNotEmpty && !_groupMemberNames.containsKey(senderId)) {
        _groupMemberNames[senderId] = eventName;
      }
    }
    if (_loadingInitial || !_groupProfilesReady) return;
    for (final entry in senders.entries) {
      unawaited(
        _loadGroupMemberProfileName(
          entry.key,
          phoneHint: entry.value.senderPhone,
        ),
      );
    }
  }

  void _seedGroupProfile2FromMemory() {
    if (!_isGroupChat) return;
    final contacts = ContactService.matrixContactsSnapshot(
      widget.currentUserId,
    );
    for (final contact in contacts) {
      final localpart = _matrixLocalpart(contact.wrytteUserId ?? '');
      final name = _cleanDisplayName(contact.formattedName);
      final avatar = contact.avatarUrl?.trim() ?? '';
      if (localpart.isEmpty || name.isEmpty) continue;
      _groupMemberNames[localpart] = name;
      if (avatar.isNotEmpty) _groupMemberAvatars[localpart] = avatar;
    }
  }

  bool _isLocalOutgoingEcho(ChatMessage message) =>
      _isMine(message) && _isLocalOutgoingEchoId(message.id);

  void _normaliseMessagesToConversation(String conversationId) {
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      if (message.conversationId != widget.conversationId) continue;
      _messages[i] = message.copyWith(conversationId: conversationId);
    }
  }

  void _upsertMessage(ChatMessage msg) {
    final exactIdx = _messages.indexWhere((m) => m.id == msg.id);
    if (exactIdx != -1) {
      _messages[exactIdx] = msg;
      return;
    }
    final optimisticId = _matchingOptimisticId(msg);
    if (optimisticId != null) {
      _replaceOptimisticMessage(optimisticId, msg);
      return;
    }
    _messages.add(msg);
  }

  String? _matchingOptimisticId(ChatMessage msg) {
    for (final entry in _optimisticIdByContent.entries) {
      final optimistic = _messages.firstWhere(
        (m) => m.id == entry.value,
        orElse: () => msg,
      );
      if (optimistic.id != entry.value) continue;
      if (optimistic.status != MessageStatus.sending) continue;
      if (!_isMine(optimistic)) continue;
      final sameContent = optimistic.content == msg.content;
      final sameAttachment =
          optimistic.attachmentType?.isNotEmpty == true &&
          optimistic.attachmentType == msg.attachmentType;
      final sameConversation =
          optimistic.conversationId == msg.conversationId ||
          optimistic.conversationId == widget.conversationId ||
          optimistic.conversationId == _resolvedConversationId;
      final sameReceiver =
          optimistic.receiverId == msg.receiverId ||
          optimistic.receiverId == msg.senderId ||
          _matrixLocalpart(optimistic.receiverId) ==
              _matrixLocalpart(msg.receiverId) ||
          _matrixLocalpart(optimistic.receiverId) ==
              _matrixLocalpart(msg.senderId);
      final closeInTime =
          msg.timestamp.difference(optimistic.timestamp).inSeconds.abs() < 60;
      final ownMatrixEcho =
          _isMine(msg) &&
          (sameContent || sameAttachment) &&
          sameConversation &&
          closeInTime;
      if (((sameContent || sameAttachment) && sameReceiver && closeInTime) ||
          ownMatrixEcho) {
        apkLog(
          'ChatScreen.reconcile',
          'replace optimistic id=${optimistic.id} with Matrix id=${msg.id}',
        );
        return optimistic.id;
      }
    }
    return null;
  }

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    return '@${_matrixLocalpart(trimmed)}:${MatrixConfig.serverName}';
  }

  void _replaceOptimisticMessage(String optimisticId, ChatMessage sent) {
    _messages.removeWhere((m) => m.id == sent.id && m.id != optimisticId);
    final idx = _messages.indexWhere((m) => m.id == optimisticId);
    if (idx != -1) {
      _messages[idx] = sent;
    } else {
      _upsertMessage(sent);
    }
    _messages.removeWhere((m) => _isDuplicateOutgoingEcho(m, sent));
    _optimisticIdByContent.removeWhere((_, id) => id == optimisticId);
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  void _removeDuplicateOutgoingEchoes() {
    final canonicalOutgoing =
        _messages
            .where((m) => _isMine(m) && !_isLocalOutgoingEchoId(m.id))
            .toList();
    if (canonicalOutgoing.isEmpty) return;
    _messages.removeWhere(
      (candidate) => canonicalOutgoing.any(
        (sent) => _isDuplicateOutgoingEcho(candidate, sent),
      ),
    );
  }

  bool _isDuplicateOutgoingEcho(ChatMessage candidate, ChatMessage sent) {
    if (candidate.id == sent.id) return false;
    if (!_isMine(candidate) || !_isMine(sent)) return false;
    if (!_isLocalOutgoingEchoId(candidate.id)) return false;
    final sameContent = candidate.content == sent.content;
    final sameAttachment =
        candidate.attachmentType?.isNotEmpty == true &&
        candidate.attachmentType == sent.attachmentType;
    if (!sameContent && !sameAttachment) return false;
    final sameConversation =
        candidate.conversationId == sent.conversationId ||
        candidate.conversationId == widget.conversationId ||
        candidate.conversationId == _resolvedConversationId;
    if (!sameConversation) return false;
    final closeInTime =
        candidate.timestamp.difference(sent.timestamp).inSeconds.abs() < 60;
    return closeInTime;
  }

  bool _isLocalOutgoingEchoId(String id) {
    return id.startsWith('opt_') ||
        id.startsWith('attach_') ||
        id.startsWith('voice_') ||
        id.startsWith('video_') ||
        id.startsWith('Wrytte-');
  }

  Future<void> _showMessageActions(ChatMessage message) async {
    final isMine = _isMine(message);
    final room = MatrixChatService.instance.getRoomById(message.conversationId);
    final isAdminInGroup =
        _isGroupChat &&
        room != null &&
        MatrixChatService.instance.isMatrixGroupRoom(room) &&
        MatrixChatService.instance.isGroupAdmin(room, room.client.userID ?? '');
    final isGroupOwner =
        _isGroupChat &&
        room != null &&
        room.creatorUserIds.contains(room.client.userID?.trim() ?? '');
    final isMessageSenderAdmin =
        _isGroupChat &&
        room != null &&
        MatrixChatService.instance.isMatrixGroupRoom(room) &&
        MatrixChatService.instance.isGroupAdmin(room, message.senderId);
    final canDeleteForEveryone = isMine || (isAdminInGroup && room.canRedact);
    final attachmentType = message.attachmentType?.trim();
    final hasAttachment = attachmentType != null && attachmentType.isNotEmpty;
    final isPinnedForEveryone = _pinnedEventIds.contains(message.id);
    final isPinnedForMe = _pinnedForMeEventIds.contains(message.id);
    final isPinnableEvent =
        !_pinUpdatesInFlight.contains(message.id) &&
        !message.isDeleted &&
        message.status != MessageStatus.sending &&
        message.status != MessageStatus.failed &&
        message.id.startsWith(r'$');
    final canPin =
        !_isReadOnlySuggestedGroup &&
        room != null &&
        room.canChangeStateEvent(mx.EventTypes.RoomPinnedEvents) &&
        isPinnableEvent;
    final canPinForMe = !_isGroupChat && room != null && isPinnableEvent;
    final link = _firstLinkIn(message.content);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111318),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  if (!_isReadOnlySuggestedGroup)
                    _messageActionTile(
                      icon: Icons.reply,
                      label: 'Reply',
                      onTap: () {
                        Navigator.pop(context);
                        setState(() => _replyingTo = message);
                        _focusNode.requestFocus();
                      },
                    ),
                  _messageActionTile(
                    icon: Icons.shortcut_rounded,
                    label: 'Forward',
                    onTap: () {
                      Navigator.pop(context);
                      _promptForward(message);
                    },
                  ),
                  if (_isReadOnlySuggestedGroup)
                    _messageActionTile(
                      icon: Icons.copy_outlined,
                      label: link != null ? 'Copy link' : 'Copy',
                      onTap: () {
                        Navigator.pop(context);
                        Clipboard.setData(
                          ClipboardData(text: link ?? message.content),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              link != null ? 'Link copied' : 'Copied',
                            ),
                          ),
                        );
                      },
                    )
                  else if (!hasAttachment && link != null) ...[
                    _messageActionTile(
                      icon: Icons.copy_outlined,
                      label: 'Copy link',
                      onTap: () {
                        Navigator.pop(context);
                        Clipboard.setData(ClipboardData(text: link));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copied')),
                        );
                      },
                    ),
                  ] else if (!hasAttachment)
                    _messageActionTile(
                      icon: Icons.copy_outlined,
                      label: 'Copy',
                      onTap: () {
                        Navigator.pop(context);
                        Clipboard.setData(ClipboardData(text: message.content));
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('Copied')));
                      },
                    ),
                  if (canPin)
                    _messageActionTile(
                      icon:
                          isPinnedForEveryone
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                      label:
                          isPinnedForEveryone
                              ? (_isGroupChat ? 'Unpin' : 'Unpin for everyone')
                              : (_isGroupChat ? 'Pin' : 'Pin for everyone'),
                      onTap: () {
                        Navigator.pop(context);
                        _setMessagePinned(
                          message,
                          pinned: !isPinnedForEveryone,
                        );
                      },
                    ),
                  if (canPinForMe)
                    _messageActionTile(
                      icon:
                          isPinnedForMe
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                      label: isPinnedForMe ? 'Unpin for me' : 'Pin for me',
                      onTap: () {
                        Navigator.pop(context);
                        _setMessagePinnedForMe(message, pinned: !isPinnedForMe);
                      },
                    ),
                  if (!_isReadOnlySuggestedGroup &&
                      !hasAttachment &&
                      link != null)
                    _messageActionTile(
                      icon: Icons.open_in_new,
                      label: 'Open link',
                      onTap: () {
                        Navigator.pop(context);
                        _openLink(link);
                      },
                    ),
                  if (!_isReadOnlySuggestedGroup &&
                      _isGroupChat &&
                      isAdminInGroup &&
                      !isMine &&
                      !isMessageSenderAdmin &&
                      !message.isDeleted)
                    _messageActionTile(
                      icon: Icons.person_remove_outlined,
                      label: 'Remove from group',
                      destructive: true,
                      onTap: () {
                        Navigator.pop(context);
                        _removeMessageSenderFromGroup(message);
                      },
                    ),
                  if (hasAttachment && !_isReadOnlySuggestedGroup)
                    _messageActionTile(
                      icon: Icons.save_alt_outlined,
                      label: _saveAttachmentLabel(attachmentType),
                      onTap: () {
                        Navigator.pop(context);
                        _saveAttachmentToDevice(message);
                      },
                    ),
                  if (!_isReadOnlySuggestedGroup && _canEditMessage(message))
                    _messageActionTile(
                      icon: Icons.edit_outlined,
                      label: 'Edit',
                      onTap: () {
                        Navigator.pop(context);
                        _promptEditMessage(message);
                      },
                    ),
                  if (!_isGroupChat)
                    _messageActionTile(
                      icon: Icons.delete_outline,
                      label: 'Delete for me',
                      onTap: () async {
                        Navigator.pop(context);
                        await _chat.deleteMessageForMe(message);
                        if (!mounted) return;
                        setState(() {
                          _messages.removeWhere((m) => m.id == message.id);
                        });
                      },
                    ),
                  if (!_isReadOnlySuggestedGroup &&
                      canDeleteForEveryone &&
                      !message.isDeleted &&
                      message.status != MessageStatus.sending &&
                      message.status != MessageStatus.failed &&
                      !message.id.startsWith('opt_'))
                    _messageActionTile(
                      icon: Icons.delete_forever_outlined,
                      label: 'Delete for everyone',
                      destructive: true,
                      onTap: () async {
                        Navigator.pop(context);
                        try {
                          await _chat.deleteMessageForEveryone(message);
                          if (!mounted) return;
                          setState(() {
                            _upsertMessage(
                              message.copyWith(
                                content:
                                    isMine
                                        ? 'This message was deleted'
                                        : 'This message was deleted by admin',
                                isDeletedForEveryone: true,
                              ),
                            );
                          });
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Could not delete message: $e'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      },
                    ),
                  if (_isReadOnlySuggestedGroup &&
                      !isMine &&
                      !message.isDeleted &&
                      message.status != MessageStatus.sending &&
                      message.status != MessageStatus.failed &&
                      !message.id.startsWith('opt_'))
                    _messageActionTile(
                      icon: Icons.report_gmailerrorred_outlined,
                      label: 'Report',
                      destructive: true,
                      onTap: null,
                    ),
                  if (!_isReadOnlySuggestedGroup &&
                      _isGroupChat &&
                      !isGroupOwner &&
                      !isMine &&
                      !message.isDeleted &&
                      message.status != MessageStatus.sending &&
                      message.status != MessageStatus.failed &&
                      !message.id.startsWith('opt_'))
                    _messageActionTile(
                      icon: Icons.report_gmailerrorred_outlined,
                      label: 'Report',
                      destructive: true,
                      onTap: () {
                        Navigator.pop(context);
                        _reportGroupMessage(message);
                      },
                    ),
                  if (!_isReadOnlySuggestedGroup &&
                      message.status == MessageStatus.sending)
                    _messageActionTile(
                      icon: Icons.close,
                      label: 'Cancel',
                      onTap: () async {
                        Navigator.pop(context);
                        await _chat.cancelLocalMessage(message);
                        if (!mounted) return;
                        setState(() {
                          _messages.removeWhere((m) => m.id == message.id);
                        });
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _setMessagePinnedForMe(
    ChatMessage message, {
    required bool pinned,
  }) async {
    if (_isGroupChat || !_pinUpdatesInFlight.add(message.id)) return;
    final previousIds = List<String>.from(_pinnedForMeEventIds);
    final optimisticIds = List<String>.from(previousIds)
      ..removeWhere((id) => id == message.id);
    if (pinned) optimisticIds.insert(0, message.id);
    setState(() => _pinnedForMeEventIds = optimisticIds);
    try {
      final ids = await _chat.setMessagePinnedForMe(message, pinned: pinned);
      if (!mounted) return;
      setState(() => _pinnedForMeEventIds = ids);
    } catch (error) {
      if (!mounted) return;
      setState(() => _pinnedForMeEventIds = previousIds);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not ${pinned ? 'pin' : 'unpin'} message for you: $error',
          ),
        ),
      );
    } finally {
      _pinUpdatesInFlight.remove(message.id);
    }
  }

  Future<void> _setMessagePinned(
    ChatMessage message, {
    required bool pinned,
  }) async {
    final now = DateTime.now();
    final lastUpdate = _lastPinUpdateAt[message.id];
    if (lastUpdate != null &&
        now.difference(lastUpdate) < const Duration(seconds: 1)) {
      return;
    }
    if (!_pinUpdatesInFlight.add(message.id)) return;
    _lastPinUpdateAt[message.id] = now;
    final previousIds = List<String>.from(_pinnedEventIds);
    final previousNotice = _latestPinActivityNotice;
    final previousNoticeAnchor = _pinActivityAnchorEventId;
    final optimisticIds = List<String>.from(previousIds)
      ..removeWhere((id) => id == message.id);
    if (pinned) optimisticIds.insert(0, message.id);
    setState(() {
      _pinnedEventIds = optimisticIds;
      if (pinned) {
        _latestPinActivityNotice = 'You pinned a message';
        _pinActivityAnchorEventId =
            _messages.isEmpty ? null : _messages.last.id;
      } else {
        _latestPinActivityNotice = null;
        _pinActivityAnchorEventId = null;
      }
    });
    try {
      final ids = await _chat.setMessagePinnedForEveryone(
        message,
        pinned: pinned,
      );
      if (!mounted) return;
      setState(() => _pinnedEventIds = ids);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _pinnedEventIds = previousIds;
        _latestPinActivityNotice = previousNotice;
        _pinActivityAnchorEventId = previousNoticeAnchor;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not ${pinned ? 'pin' : 'unpin'} message: $error',
          ),
        ),
      );
    } finally {
      _pinUpdatesInFlight.remove(message.id);
    }
  }

  Future<void> _reportGroupMessage(ChatMessage message) async {
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF23262C),
            title: const Text(
              'Report message',
              style: TextStyle(color: Colors.white),
            ),
            content: TextField(
              controller: reasonController,
              autofocus: true,
              maxLines: 3,
              maxLength: 500,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Why are you reporting this message?',
                hintStyle: TextStyle(color: Colors.white54),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final value = reasonController.text.trim();
                  if (value.isNotEmpty) Navigator.pop(dialogContext, value);
                },
                child: const Text('Report'),
              ),
            ],
          ),
    );
    reasonController.dispose();
    if (reason == null || reason.trim().isEmpty || !mounted) return;

    try {
      await MatrixChatService.instance.reportGroupMember(
        roomId: message.conversationId,
        eventId: message.id,
        reportedUserId: message.senderId,
        reason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message reported')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not report message: $error'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _removeMessageSenderFromGroup(ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF23262C),
            title: const Text(
              'Remove member',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'Remove this member from the group?',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text(
                  'Remove',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await MatrixChatService.instance.removeGroupMember(
        roomId: message.conversationId,
        userId: message.senderId,
        reason: 'Removed by group admin',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Member removed from the group')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not remove member: $error'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  bool _canEditMessage(ChatMessage message) {
    if (!_isMine(message)) return false;
    if (message.isDeleted) return false;
    if (message.attachmentType?.trim().isNotEmpty == true ||
        message.hasAttachment ||
        message.isVoiceNote) {
      return false;
    }
    if (message.status == MessageStatus.sending ||
        message.status == MessageStatus.failed) {
      return false;
    }
    if (message.id.startsWith('opt_')) return false;
    return message.content.trim().isNotEmpty;
  }

  String _saveAttachmentLabel(String? type) {
    switch (type) {
      case 'image':
        return 'Save image';
      case 'video':
        return 'Save video';
      case 'voice':
        return 'Save voice';
      case 'file':
        return 'Save file';
      default:
        return 'Save attachment';
    }
  }

  Future<void> _saveAttachmentToDevice(ChatMessage message) async {
    final path = message.attachmentUrl?.trim() ?? '';
    if (path.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attachment file was not found')),
      );
      return;
    }
    try {
      await AttachmentLocalStore.instance.ensureComplete(
        source: path,
        fileName:
            message.content.trim().isEmpty ? 'attachment' : message.content,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save attachment: $error'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_saveAttachmentLabel(message.attachmentType)} ready'),
      ),
    );
  }

  Future<void> _openLink(String link) async {
    final normalised =
        link.startsWith('http://') || link.startsWith('https://')
            ? link
            : 'https://$link';
    final uri = Uri.tryParse(normalised);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _promptEditMessage(ChatMessage message) {
    setState(() {
      _replyingTo = null;
      _editingMessage = message;
    });
    _controller
      ..text = message.content
      ..selection = TextSelection.collapsed(offset: message.content.length);
    _focusNode.requestFocus();
  }

  Widget _messageActionTile({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool destructive = false,
  }) {
    final color =
        onTap == null
            ? Colors.white38
            : destructive
            ? const Color(0xFFFF6B6B)
            : Colors.white;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }

  Future<void> _promptForward(ChatMessage message) async {
    final targets = await _buildForwardTargets();
    if (!mounted) return;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No contacts or recent chats found')),
      );
      return;
    }

    final selectedTargets = await Navigator.push<List<_ForwardTarget>>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder:
            (_) => _ForwardPickerPage(
              targets: targets,
              previewText: _replyPreviewForMessage(message) ?? 'Message',
              previewAvatarUrl: widget.avatarUrl,
            ),
      ),
    );
    if (selectedTargets == null || selectedTargets.isEmpty) return;

    var sent = 0;
    for (final target in selectedTargets) {
      try {
        await _chat.forwardMessage(
          original: message,
          receiverId: target.receiverId,
          conversationId: target.conversationId,
        );
        sent++;
      } catch (e) {
        apkLog(
          'ChatScreen.forward',
          'forward FAILED target="${target.receiverId}" error="$e"',
        );
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent == selectedTargets.length
              ? 'Message forwarded'
              : 'Forwarded to $sent of ${selectedTargets.length}',
        ),
        backgroundColor:
            sent == selectedTargets.length ? null : Colors.redAccent,
      ),
    );
  }

  Future<List<_ForwardTarget>> _buildForwardTargets() async {
    final sourceRoom = MatrixChatService.instance.getRoomById(
      _activeConversationId,
    );
    final restrictOwnerGroupTargets =
        _isGroupChat &&
        sourceRoom != null &&
        MatrixChatService.instance.isMatrixGroupRoom(sourceRoom) &&
        MatrixChatService.instance.isGroupOwner(sourceRoom);
    final ownerUserId =
        (await AuthService.instance.getCurrentUserId())?.trim() ??
        widget.currentUserId.trim();
    final identities =
        ownerUserId.isEmpty
            ? <String, ContactIdentity>{}
            : await ContactIdentityCache.instance.loadAll(
              ownerUserId: ownerUserId,
            );
    final byKey = <String, _ForwardTarget>{};
    final canonicalKeyByAlias = <String, String>{};
    var order = 0;

    void addTarget(_ForwardTarget target) {
      if (target.receiverId.trim().isEmpty) return;
      if (_isOwnMatrixId(target.receiverId)) return;
      final aliases = _forwardTargetAliases(target.receiverId, target.phone);
      if (aliases.isEmpty) return;
      String? matchedKey;
      for (final alias in aliases) {
        matchedKey ??= canonicalKeyByAlias[alias];
      }
      final key = matchedKey ?? aliases.first;
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = target.copyWith(sortOrder: order++);
        for (final alias in aliases) {
          canonicalKeyByAlias[alias] = key;
        }
        return;
      }
      if (existing.conversationId == null && target.conversationId != null) {
        byKey[key] = existing.copyWith(
          conversationId: target.conversationId,
          receiverId: target.receiverId,
          subtitle:
              existing.subtitle?.trim().isNotEmpty == true
                  ? existing.subtitle
                  : target.subtitle,
          avatarUrl:
              existing.avatarUrl?.trim().isNotEmpty == true
                  ? existing.avatarUrl
                  : target.avatarUrl,
        );
      }
      if (!existing.isSavedContact && target.isSavedContact) {
        byKey[key] = target.copyWith(
          conversationId: existing.conversationId ?? target.conversationId,
          receiverId:
              existing.conversationId != null
                  ? existing.receiverId
                  : target.receiverId,
          subtitle:
              existing.subtitle?.trim().isNotEmpty == true
                  ? existing.subtitle
                  : target.subtitle,
          avatarUrl:
              target.avatarUrl?.trim().isNotEmpty == true
                  ? target.avatarUrl
                  : existing.avatarUrl,
          sortOrder: existing.sortOrder,
        );
      }
      for (final alias in aliases) {
        canonicalKeyByAlias[alias] = key;
      }
    }

    if (ownerUserId.isNotEmpty) {
      final contacts = await ContactLocalDb.loadSavedContacts(
        ownerUserId: ownerUserId,
      );
      for (final contact in contacts) {
        final receiverId =
            contact.wrytteUserId?.trim().isNotEmpty == true
                ? contact.wrytteUserId!.trim()
                : contact.primaryPhone.trim();
        final name = _cleanDisplayName(contact.displayName);
        final phone = _firstPhoneFrom(contact.phones);
        addTarget(
          _ForwardTarget(
            receiverId: receiverId,
            title:
                name.isNotEmpty
                    ? name
                    : phone.isNotEmpty
                    ? phone
                    : receiverId,
            subtitle: phone,
            avatarUrl: contact.avatarUrl,
            phone: phone,
            isSavedContact: true,
          ),
        );
      }
    }

    for (final conversation in _chat.cachedConversationsSnapshot) {
      if (conversation.isGroupKind || conversation.isChannelKind) continue;
      final receiverId = conversation.otherUserId.trim();
      if (receiverId.isEmpty || receiverId.startsWith('!')) continue;
      if (restrictOwnerGroupTargets) {
        final history = await _chat.loadCachedMessages(conversation.id);
        final hasIncomingMessage = history.any(
          (message) =>
              !message.isDeleted &&
              message.senderId.trim().isNotEmpty &&
              !_isOwnMatrixId(message.senderId),
        );
        if (!hasIncomingMessage) continue;
      }
      final identity = identities[_matrixLocalpart(receiverId).toLowerCase()];
      var phone = _firstPhoneFrom([
        identity?.phone ?? '',
        conversation.otherUserName,
        conversation.otherUserId,
        conversation.lastMessageSenderId,
        ...conversation.participants,
      ]);
      if (phone.isEmpty) {
        phone = _phoneFromMatrixLocalpart(receiverId);
      }
      final name = _cleanDisplayName(
        identity?.savedName ??
            identity?.profileName ??
            conversation.otherUserName,
      );
      addTarget(
        _ForwardTarget(
          conversationId: conversation.id,
          receiverId: receiverId,
          title:
              name.isNotEmpty
                  ? name
                  : phone.isNotEmpty
                  ? phone
                  : _matrixLocalpart(receiverId),
          subtitle: '',
          avatarUrl: identity?.avatarUrl ?? conversation.otherUserAvatar,
          phone: phone,
          isSavedContact: false,
        ),
      );
    }

    final targets =
        byKey.values.toList()..sort((a, b) {
          if (a.isSavedContact != b.isSavedContact) {
            return a.isSavedContact ? -1 : 1;
          }
          return a.sortOrder.compareTo(b.sortOrder);
        });
    return targets;
  }

  List<String> _forwardTargetAliases(String receiverId, String? phone) {
    final aliases = <String>[];
    var normalizedPhone = _firstPhoneFrom([phone, receiverId]);
    if (normalizedPhone.isEmpty) {
      normalizedPhone = _phoneFromMatrixLocalpart(receiverId);
    }
    final phoneKey = _forwardPhoneKey(normalizedPhone);
    if (phoneKey.isNotEmpty) aliases.add('ph:$phoneKey');
    final localpart = _matrixLocalpart(receiverId).trim().toLowerCase();
    if (localpart.isNotEmpty &&
        !localpart.startsWith('!') &&
        !localpart.contains(' ')) {
      aliases.add('mx:$localpart');
    }
    return aliases;
  }

  String _phoneFromMatrixLocalpart(String value) {
    final localpart = _matrixLocalpart(value).trim();
    if (!RegExp(r'^\+?\d{7,15}$').hasMatch(localpart)) return '';
    return _formatPhone(localpart);
  }

  String _forwardPhoneKey(String value) {
    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    return digits.length >= 7 && digits.length <= 15 ? digits : '';
  }

  // ─── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final double statusBarH = _stableStatusBarH ?? mediaQuery.viewPadding.top;
    final double appBarH = statusBarH + kToolbarHeight;
    final double keyboardInset =
        _focusNode.hasFocus ? mediaQuery.viewInsets.bottom : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBody: true,
      resizeToAvoidBottomInset: false,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Color(0xFF08090B),
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        child: ScrollConfiguration(
          behavior: const _ChatScrollBehavior(),
          child: Stack(
            children: [
              Column(
                children: [
                  _buildAppBar(statusBarH),
                  PinnedEventsStrip(
                    pinnedEventIds: _visiblePinnedEventIds,
                    events: _messages,
                    onOpenEvent: _openPinnedMessage,
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: keyboardInset),
                      child: Column(
                        children: [
                          Expanded(child: _buildMessageList()),
                          if (_someoneElseTyping) const _TypingIndicator(),


                          if (_isReadOnlySuggestedGroup)
                            _buildJoinGroupBottomBar()
                          else if (_isDeletedConversation)
                            _buildDeletedGroupBottomBar()
                          else if (!_isDeletedConversation)
                            MultiProvider(
                              providers: [
                                Provider<AudioRecordingRepository>(
                                  create: (_) => SourceComposerAudioRepository(),
                                ),
                                Provider<CameraRepository>(
                                  create: (_) => CameraRepositoryImpl(
                                    DeviceCameraService(),
                                    const CameraCapabilitiesService(),
                                    CameraSessionManager(),
                                  ),
                                  dispose: (_, repository) =>
                                      unawaited(repository.close()),
                                ),
                                Provider<MediaLibraryRepository>(
                                  create: (_) => MediaLibraryRepositoryImpl(
                                    DeviceMediaLibraryService(),
                                  ),
                                ),
                                Provider<AttachmentPickerRepository>(
                                  create: (_) => AttachmentPickerRepositoryImpl(
                                    DeviceAttachmentPickerService(),
                                  ),
                                ),
                              ],
                              child: ChatComposer(
                                controller: _controller,
                                focusNode: _focusNode,
                                recordMode: _recordMode,
                                onSend: (text) => unawaited(_send()),
                                onToggleRecordMode: _toggleRecordMode,
                                onAttachmentPressed: _openAttachments,
                                onExpressPressed: () {},
                                replySender: _replyingTo == null
                                    ? null
                                    : (_isMine(_replyingTo!) ? 'You' : widget.title),
                                replyPreview: _replyingTo == null
                                    ? null
                                    : _replyPreviewForMessage(_replyingTo!),
                                onCancelReply: _replyingTo == null
                                    ? null
                                    : () => setState(() => _replyingTo = null),
                                isEditing: _editingMessage != null,
                                editingMediaSource: null,
                                editingMediaType: null,
                                onCancelEdit: _editingMessage == null
                                    ? null
                                    : () {
                                        setState(() => _editingMessage = null);
                                        _controller.clear();
                                      },
                                onVoiceRecorded: (recording) {
                                  unawaited(_sendVoiceNote(
                                    recording.path,
                                    recording.trimRange.duration.inSeconds.clamp(1, 3600),
                                  ));
                                },
                                onRoundVideoRecorded: (recording) {
                                  unawaited(_sendVideoNote(
                                    recording.path,
                                    (recording.duration ?? const Duration(seconds: 1))
                                        .inSeconds
                                        .clamp(1, 60),
                                  ));
                                },
                                onRecordingFailure: (msg) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(msg)),
                                  );
                                },
                                onRecordingActiveChanged: (_) {},
                              ),
                            )
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              // ── debug overlay ─────────────────────────────────────────────
              if (_showDebug) _buildDebugOverlay(appBarH),

              // ── debug toggle button ───────────────────────────────────────
              Positioned(
                bottom: 120 + keyboardInset,
                right: 12,
                child: GestureDetector(
                  onTap: () => setState(() => _showDebug = !_showDebug),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color:
                          _showDebug
                              ? Colors.orangeAccent
                              : Colors.grey.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Text('🐛', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── DEBUG OVERLAY ─────────────────────────────────────────────────────────

  Widget _buildDebugOverlay(double topOffset) {
    final lines = _logger.lines;

    return Positioned(
      top: topOffset + 4,
      left: 4,
      right: 4,
      bottom: 140,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orangeAccent, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── header ───────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: const BoxDecoration(
                color: Colors.orangeAccent,
                borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'APK DEBUG LOG',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  // Copy all logs button
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: lines.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Logs copied to clipboard'),
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'COPY',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  // Clear button
                  GestureDetector(
                    onTap: () {
                      _logger.clear();
                      setState(() {});
                    },
                    child: const Text(
                      'CLR',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Close button
                  GestureDetector(
                    onTap: () => setState(() => _showDebug = false),
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),

            // ── log lines ────────────────────────────────────────────────────
            Expanded(
              child:
                  lines.isEmpty
                      ? const Center(
                        child: Text(
                          'No logs yet.\nTry sending a message.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      )
                      : ListView.builder(
                        controller: _debugScrollCtrl,
                        padding: const EdgeInsets.all(6),
                        itemCount: lines.length,
                        itemBuilder: (_, i) {
                          final line = lines[i];
                          // Colour-code by severity
                          Color c = Colors.white70;
                          if (line.contains('❌') ||
                              line.contains('🚨') ||
                              line.contains('FAIL') ||
                              line.contains('ERROR') ||
                              line.contains('TIMEOUT')) {
                            c = const Color(0xFFFF6B6B);
                          } else if (line.contains('⚠️') ||
                              line.contains('WARN') ||
                              line.contains('MISMATCH')) {
                            c = const Color(0xFFFFD93D);
                          } else if (line.contains('✅')) {
                            c = const Color(0xFF6BCB77);
                          } else if (line.contains('🔄') ||
                              line.contains('⏳')) {
                            c = const Color(0xFF4DA3FF);
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: SelectableText(
                              line,
                              style: TextStyle(
                                color: c,
                                fontSize: 10,
                                fontFamily: 'monospace',
                                height: 1.35,
                              ),
                            ),
                          );
                        },
                      ),
            ),

            // ── summary bar ──────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A2E),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(11),
                ),
              ),
              child: Text(
                'convId: ${_resolvedConversationId ?? "not resolved"}  '
                '|  receiver: ${_normaliseId(widget.receiverId)}  '
                '|  msgs: ${_messages.length}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── MESSAGE LIST ──────────────────────────────────────────────────────────

  Future<void> _openPinnedMessage(String eventId) async {
    var messageIndex = _messages.indexWhere((message) => message.id == eventId);
    if (messageIndex < 0) {
      final room = MatrixChatService.instance.getRoomById(
        _activeConversationId,
      );
      final event = await room?.getEventById(eventId);
      final message = event == null ? null : ChatMessage.fromMatrixEvent(event);
      if (message != null && mounted) {
        setState(() => _mergeMessages([message]));
        messageIndex = _messages.indexWhere(
          (candidate) => candidate.id == eventId,
        );
      }
    }
    if (!mounted) return;
    if (messageIndex < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pinned message is not available')),
      );
      return;
    }

    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = eventId);
    if (_scrollCtrl.hasClients && _messages.length > 1) {
      final reverseIndex = _messages.length - 1 - messageIndex;
      final ratio = reverseIndex / (_messages.length - 1);
      final target = (_scrollCtrl.position.maxScrollExtent * ratio).clamp(
        0.0,
        _scrollCtrl.position.maxScrollExtent,
      );
      await _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    }
    if (!context.mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) return;
    final messageContext = _messageKeys[eventId]?.currentContext;
    if (messageContext != null) {
      await Scrollable.ensureVisible(
        messageContext,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: 0.45,
      );
    }
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _highlightedMessageId == eventId) {
        setState(() => _highlightedMessageId = null);
      }
    });
  }

  Widget _buildMessageList() {
    if (_isDeletedConversation) {
      return const SizedBox.expand();
    }
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              _messages.isEmpty && !_loadingInitial
                  ? Center(
                    child: Text(
                      'No messages yet.\nSay hello!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 15,
                        height: 1.6,
                      ),
                    ),
                  )
                  : _messages.isEmpty
                  ? const SizedBox.expand()
                  : ListView.builder(
                    controller: _scrollCtrl,
                    reverse: true,
                    padding: const EdgeInsets.only(top: 150, bottom: 12),
                    physics: const ClampingScrollPhysics(),
                    itemCount:
                        _messages.length +
                        (_shouldLiftShortConversation ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (_shouldLiftShortConversation && index == 0) {
                        return const SizedBox(height: 96);
                      }

                      final adjustedIndex =
                          index - (_shouldLiftShortConversation ? 1 : 0);
                      final msgIndex = _messages.length - 1 - adjustedIndex;
                      final msg = _messages[msgIndex];
                      final isMine = _isMine(msg);
                      final previousChronological =
                          msgIndex > 0 ? _messages[msgIndex - 1] : null;
                      final nextChronological =
                          msgIndex + 1 < _messages.length
                              ? _messages[msgIndex + 1]
                              : null;
                      final showDate =
                          previousChronological == null ||
                          !_isSameDay(
                            previousChronological.timestamp,
                            msg.timestamp,
                          );

                      final showTail =
                          nextChronological == null ||
                          _isMine(nextChronological) != isMine ||
                          !_isSameDay(
                            nextChronological.timestamp,
                            msg.timestamp,
                          );



                      final showGroupAvatar =
                          !_isGroupChat ||
                          isMine ||
                          nextChronological == null ||
                          !_isSameDay(
                            nextChronological.timestamp,
                            msg.timestamp,
                          ) ||
                          nextChronological.senderId.trim().toLowerCase() !=
                              msg.senderId.trim().toLowerCase();
                      final effectiveAttachmentType = _effectiveAttachmentType(
                        msg,
                      );
                      return Column(
                        key: _messageKeys.putIfAbsent(
                          msg.id,
                          () => GlobalKey(debugLabel: 'message:${msg.id}'),
                        ),
                        children: [
                          if (showDate)
                            _buildDateDivider(
                              _formatDateDivider(msg.timestamp),
                            ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () => _showMessageActions(msg),
                            child: _buildGroupAwareMessageBubble(
                              msg: msg,
                              isMine: isMine,
                              showTail: showTail,
                              showGroupAvatar: showGroupAvatar,
                              effectiveAttachmentType: effectiveAttachmentType,
                            ),
                          ),
                          if (nextChronological != null &&
                              _isSameDay(
                                nextChronological.timestamp,
                                msg.timestamp,
                              ))
                            SizedBox(
                              height: _isMine(nextChronological) == isMine
                                  ? 2
                                  : 7,
                            ),
                          if (msg.id == _pinActivityAnchorEventId &&
                              _latestPinActivityNotice != null)
                            _buildPinActivityNotice(_latestPinActivityNotice!),
                        ],
                      );
                    },
                  ),
              if (_loadingOlder)
                const Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF4DA3FF),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPinActivityNotice(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF202328).withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            child: Text(
              text,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildJoinGroupBottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: _joiningSuggestedGroup ? null : _joinSuggestedGroup,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF4DA3FF),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(
                0xFF4DA3FF,
              ).withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child:
                _joiningSuggestedGroup
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : const Text(
                      'Join',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeletedGroupBottomBar() {
    final groupName =
        _resolvedHeaderName.trim().isNotEmpty
            ? _resolvedHeaderName.trim()
            : widget.title.trim().isNotEmpty
            ? widget.title.trim()
            : 'This';
    final groupLabel =
        groupName.toLowerCase().endsWith('group')
            ? groupName
            : '$groupName group';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 62),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF17191E),
            borderRadius: BorderRadius.circular(27),
            border: Border.all(color: const Color(0xFF2A2D34)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lock_outline,
                color: Color(0xFF9A9CA3),
                size: 20,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  '$groupLabel\nhas been deleted',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF9A9CA3),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _joinSuggestedGroup() async {
    if (_joiningSuggestedGroup) return;
    setState(() => _joiningSuggestedGroup = true);
    try {
      final room = await MatrixChatService.instance.joinGroup(
        widget.groupAlias?.trim().isNotEmpty == true
            ? widget.groupAlias!
            : _activeConversationId,
      );
      if (room != null) {
        _resolvedConversationId = room.id;
      }
      await _chat.saveJoinedGroupShell(
        roomId: room?.id ?? _activeConversationId,
        name: _resolvedHeaderName,
        avatarUrl: _stableHeaderAvatarUrl,
      );
      if (room != null) {
        await _chat.fetchConversations();
        unawaited(_loadGroupMemberProfiles(room.id));
      }
      if (!mounted) return;
      setState(() {
        _joinedSuggestedGroup = true;
        _joiningSuggestedGroup = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _joiningSuggestedGroup = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not join group: $e')));
    }
  }

  Widget _buildGroupAwareMessageBubble({
    required ChatMessage msg,
    required bool isMine,
    required bool showTail,
    required bool showGroupAvatar,
    required String? effectiveAttachmentType,
  }) {
    final senderName =
        _isGroupChat && !isMine ? _groupSenderName(msg.senderId) : null;
    final room = MatrixChatService.instance.getRoomById(msg.conversationId);
    final senderIsAdmin =
        _isGroupChat &&
        !isMine &&
        room != null &&
        MatrixChatService.instance.isGroupAdmin(room, msg.senderId);
    final rawDisplayedContent =
        msg.isDeletedForEveryone &&
                !msg.content.toLowerCase().startsWith(
                  'this message was deleted',
                )
            ? (isMine
                ? 'This message was deleted'
                : 'This message was deleted by admin')
            : msg.content;
    // Defensively clean legacy SQLite rows written before edited Matrix reply
    // fallbacks (`* > <@user:server> ...`) were handled by the model parser.
    // This also prevents the quoted homeserver from becoming a link preview.
    final displayedContent = _stripMatrixReplyFallbackForDisplay(
      rawDisplayedContent,
    );

    final Widget bubble;

    final contactParts = displayedContent.split('\n');
    final isContactMessage = contactParts.length >= 3 &&
        contactParts.first.trim() == '[wrytte-contact]';

    if (isContactMessage) {
      final contactPresentation = ChatMessagePresentation(
        id: msg.id,
        kind: ChatMessageKind.contact,
        isMine: isMine,
        timeLabel: _formatTime(msg.timestamp),
        contactName: contactParts[1].trim().isEmpty
            ? 'Contact'
            : contactParts[1].trim(),
        contactPhone: contactParts.sublist(2).join('\n').trim(),
        deliveryState: _mapDeliveryState(isMine ? msg.status : null),
      );
      bubble = ContactMessageBubble(
        message: contactPresentation,
        showTail: showTail,
      );
    } else


        if (effectiveAttachmentType == 'image') {
          final presentation = ChatMessagePresentation(
            id: msg.id,
            kind: ChatMessageKind.image,
            isMine: isMine,
            timeLabel: _formatTime(msg.timestamp),
            text: _imageCaption(displayedContent),   // ← use helper
            assetPath: msg.attachmentUrl,            // raw URL is fine
            senderName: senderName,
            deliveryState: _mapDeliveryState(isMine ? msg.status : null),
            edited: msg.isEdited,
            pinned: _visiblePinnedEventIds.contains(msg.id),
          );

          bubble = ImageMessageBubble(
            message: presentation,
            showTail: true,
          );
        } else {
          bubble = MessageBubble(
            content: displayedContent,
            time: _formatTime(msg.timestamp),
            isMine: isMine,
            senderName: senderName,
            showAdminLabel: senderIsAdmin,
            showTail: showTail,
            status: isMine ? msg.status : null,
            isVoiceNote: msg.isVoiceNote,
            isVoiceListened: msg.isVoiceListened,
            onVoiceListened:
                !_isGroupChat && !isMine
                    ? () => unawaited(_chat.markVoiceMessageListened(msg))
                    : null,
            isVideoNote: effectiveAttachmentType == 'video',
            voiceDuration: msg.voiceDuration,
            audioUrl: msg.attachmentUrl,
            attachmentType: effectiveAttachmentType,
            attachmentUrl: msg.attachmentUrl,
            isForwarded: msg.isForwarded,
            isStarred: msg.isStarred,
            isPinned: _visiblePinnedEventIds.contains(msg.id),
            isHighlighted: _highlightedMessageId == msg.id,
            isDeleted: msg.isDeleted,
            isEdited: msg.isEdited,
            replyPreview: _replyPreviewDisplayText(msg.replyPreview),
            replySender: _replySenderDisplayName(msg),
            animateOnMount: true,
            maxWidth:
                _isGroupChat && !isMine
                    ? MediaQuery.sizeOf(context).width - 94
                    : null,
          );
        }

    if (!_isGroupChat || isMine) return bubble;

    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showGroupAvatar)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap:
                  () => _openGroupMemberProfile(
                    msg.senderId,
                    senderName ?? msg.senderId,
                  ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: UserAvatar(
                  size: 36,
                  imageUrl: _groupMemberAvatars[msg.senderId],
                  cacheIdentity:
                      'account:${widget.currentUserId.trim().toLowerCase()}'
                      '|user:${msg.senderId.trim().toLowerCase()}',
                  name: senderName ?? msg.senderId,
                ),
              ),
            )
          else
            const SizedBox(width: 40),
          const SizedBox(width: 6),
          Expanded(child: bubble),
        ],
      ),
    );
  }

  String _stripMatrixReplyFallbackForDisplay(String body) {
    final candidate = body.startsWith('* > ') ? body.substring(2) : body;
    final blocks = candidate.split(RegExp(r'\r?\n\r?\n'));
    if (candidate.startsWith('> ') && blocks.length > 1) {
      return blocks.sublist(1).join('\n\n').trimLeft();
    }
    return body;
  }

  Future<void> _openGroupMemberProfile(
    String matrixUserId,
    String savedNameHint,
  ) async {
    final userId = matrixUserId.trim();
    if (userId.isEmpty || _isOwnMatrixId(userId)) return;

    final directConversationId = await ChatService().findMatrixConversationId(
      userId,
    );
    final initialAvatar = _groupMemberAvatars[userId];
    await AvatarPreloadService.warm(
      initialAvatar,
      cacheIdentity: 'user:${userId.trim().toLowerCase()}',
    );
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => ProfileScreen(
              uid: userId,
              conversationId: directConversationId,
              savedNameHint: savedNameHint,
              initialAvatarUrl: initialAvatar,
            ),
      ),
    );
  }

  Future<void> _showGroupOptions() async {
    final mediaQuery = MediaQuery.of(context);
    final room = MatrixChatService.instance.getRoomById(_activeConversationId);
    final isOwner =
        room != null && MatrixChatService.instance.isGroupOwner(room);
    final items =
        _isReadOnlySuggestedGroup
            ? const [
              (Icons.link_rounded, 'Share link'),
              (Icons.report_gmailerrorred_outlined, 'Report group'),
            ]
            : isOwner
            ? const [
              (Icons.edit_outlined, 'Edit'),
              (Icons.settings_outlined, 'Settings'),
              (Icons.add_circle_outline_rounded, 'Add Story'),
            ]
            : const [
              (Icons.report_gmailerrorred_outlined, 'Report'),
              (Icons.search_rounded, 'Search'),
              (Icons.info_outline_rounded, 'Info'),
            ];
    await showMenu<void>(
      context: context,
      color: const Color(0xFF23262C),
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 240),
      position: RelativeRect.fromLTRB(
        mediaQuery.size.width - 252,
        mediaQuery.viewPadding.top + kToolbarHeight + 4,
        12,
        0,
      ),
      items:
          items
              .map(
                (item) => PopupMenuItem<void>(
                  enabled: false,
                  height: 58,
                  child: Row(
                    children: [
                      Icon(item.$1, color: Colors.white54, size: 24),
                      const SizedBox(width: 16),
                      Text(
                        item.$2,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 17,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
    );
  }

  // ─── APP BAR ───────────────────────────────────────────────────────────────

  Widget _buildAppBar(double statusBarH) {
    final isGroupChat = _isGroupChat;
    final displayName = _resolvedHeaderName;
    final avatarUrl =
        isGroupChat
            ? _stableHeaderAvatarUrl
            : _safePersonHeaderAvatar(
              _receiverProfile?.hasProfileImage == true
                  ? _receiverProfile!.profileImage
                  : _receiverIdentity?.avatarUrl ?? _stableHeaderAvatarUrl,
            );
    final localAvatarPath =
        isGroupChat
            ? null
            : _receiverProfile?.localProfileImagePath.trim().isNotEmpty == true
            ? _receiverProfile!.localProfileImagePath.trim()
            : null;

    return SizedBox(
      height: statusBarH + kToolbarHeight,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFF08090B)),
        child: Column(
          children: [
            SizedBox(height: statusBarH),
            SizedBox(
              height: kToolbarHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _glassPill(
                      width: _kHeaderPillH,
                      height: _kHeaderPillH,
                      child: const Icon(
                        Icons.arrow_back_ios_new,
                        color: Colors.white,
                        size: 16,
                      ),
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          if (isGroupChat) {
                            if (_isDeletedConversation) return;
                            final groupResult = await Navigator.push<Object?>(
                              context,
                              MaterialPageRoute(
                                builder:
                                    (_) => GroupProfileScreen(
                                      roomId:
                                          _resolvedConversationId ??
                                          widget.conversationId,
                                      groupName: displayName,
                                      avatarUrl: avatarUrl,
                                      alias: widget.groupAlias,
                                      initialDescription:
                                          widget.groupDescription,
                                      initialMemberCount:
                                          widget.initialMemberCount,
                                      initiallyJoined:
                                          !_isReadOnlySuggestedGroup,
                                    ),
                              ),
                            );
                            if (groupResult is GroupExitRequest && mounted) {
                              Navigator.pop(context, groupResult);
                            }
                            return;
                          }
                          final profileUid = _profilePeerId();
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (_) => ProfileScreen(
                                    uid: profileUid,
                                    conversationId:
                                        _resolvedConversationId ??
                                        widget.conversationId,
                                    savedNameHint: _resolvedHeaderName,
                                    initialAvatarUrl: avatarUrl,
                                  ),
                            ),
                          );
                          if (mounted) _loadReceiverProfile();
                        },
                        child: SizedBox(
                          height: _kHeaderPillH,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFF15181D),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFF23262C),
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: _kHeaderPillH,
                                  height: _kHeaderPillH,
                                  child: Center(
                                    child: UserAvatar(
                                      size: _kHeaderPillH,
                                      imageUrl: avatarUrl,
                                      cacheIdentity:
                                          isGroupChat
                                              ? MatrixChatService.instance
                                                  .roomProfileCacheIdentity(
                                                    accountId:
                                                        widget.currentUserId,
                                                    roomId:
                                                        _resolvedConversationId ??
                                                        widget.conversationId,
                                                    avatarUrl: avatarUrl,
                                                    room: MatrixChatService
                                                        .instance
                                                        .getRoomById(
                                                          _resolvedConversationId ??
                                                              widget
                                                                  .conversationId,
                                                        ),
                                                    profileVersion:
                                                        widget
                                                            .initialRoomProfileVersion,
                                                  )
                                              : 'user:${(_profilePeerId() ?? widget.receiverId).trim().toLowerCase()}',
                                      localImagePath: localAvatarPath,
                                      name: displayName,
                                      isDeleted: _isDeletedConversation,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        height: 18,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            displayName,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              height: 1.0,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      SizedBox(
                                        height: 14,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              isGroupChat
                                                  ? _groupSubtitle()
                                                  : _peerPresenceLabel(),
                                              style: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.5,
                                                ),
                                                fontSize: 12,
                                                height: 1.0,
                                              ),
                                              maxLines: 1,
                                              softWrap: false,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (isGroupChat)
                      _glassPill(
                        width: _kHeaderPillH,
                        height: _kHeaderPillH,
                        child: const Icon(
                          Icons.more_vert,
                          color: Colors.white,
                          size: 20,
                        ),
                        onTap: _showGroupOptions,
                      )
                    else ...[
                      _glassPill(
                        width: _kHeaderPillH,
                        height: _kHeaderPillH,
                        child: const Icon(
                          Icons.videocam_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                        onTap: () => _startCall(CallType.video),
                      ),
                      const SizedBox(width: 8),
                      _glassPill(
                        width: _kHeaderPillH,
                        height: _kHeaderPillH,
                        child: const Icon(
                          Icons.call_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                        onTap: () => _startCall(CallType.voice),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── HELPERS ───────────────────────────────────────────────────────────────

  int _groupMemberCount() {
    if (_isDeletedConversation) return 0;
    if (widget.initialMemberCountIsAuthoritative &&
        widget.initialMemberCount != null) {
      return widget.initialMemberCount!;
    }
    if (_isReadOnlySuggestedGroup &&
        widget.initialMemberCount != null &&
        widget.initialMemberCount! > 0) {
      return widget.initialMemberCount!;
    }
    final room = MatrixChatService.instance.getRoomById(_activeConversationId);
    final roomCount =
        _groupMembers.isNotEmpty
            ? _groupMembers
                .where((member) => member.membership == mx.Membership.join)
                .map((member) => member.id)
                .toSet()
                .length
            : room == null
            ? 0
            : MatrixChatService.instance.groupMemberCount(room);
    if (roomCount > 0) return roomCount;

    final cachedConversation = _chat.cachedConversationsSnapshot.firstWhere(
      (conversation) =>
          conversation.id == _activeConversationId ||
          conversation.id == widget.conversationId,
      orElse:
          () => ChatConversation(
            id: '',
            participants: const [],
            otherUserId: '',
            lastMessage: '',
            lastMessageSenderId: '',
            lastMessageTime: DateTime.fromMillisecondsSinceEpoch(0),
            unreadCount: 0,
            lastMessageType: 'group',
          ),
    );
    if (cachedConversation.participants.length > 1) {
      return cachedConversation.participants.length;
    }

    final ids = <String>{};
    for (final message in _messages) {
      final sender = message.senderId.trim();
      if (sender.isNotEmpty) ids.add(sender);
      final receiver = message.receiverId.trim();
      if (receiver.isNotEmpty && !receiver.startsWith('!')) ids.add(receiver);
    }
    final current = widget.currentUserId.trim();
    if (current.isNotEmpty) ids.add(current);
    return ids.length.clamp(1, 999999).toInt();
  }

  String _groupSubtitle() {
    final count = _groupMemberCount();
    return count == 1 ? '1 member' : '$count members';
  }

  bool get _isGroupChat {
    final kind = ConversationKind.normalize(widget.conversationKind);
    if (kind == ConversationKind.group || kind == ConversationKind.channel) {
      return true;
    }
    if (kind == ConversationKind.direct) return false;
    return widget.readOnlyUntilJoin ||
        _isKnownGroupConversationId(widget.receiverId) ||
        _isKnownGroupConversationId(widget.conversationId) ||
        _cachedConversationIsGroup(widget.conversationId) ||
        (_resolvedConversationId != null &&
            _cachedConversationIsGroup(_resolvedConversationId!));
  }

  String? _initialStableHeaderAvatarUrl() {
    if (_isKnownGroupConversationId(widget.conversationId) ||
        _isKnownGroupConversationId(widget.receiverId) ||
        widget.readOnlyUntilJoin) {
      final room =
          MatrixChatService.instance.getRoomById(widget.conversationId) ??
          MatrixChatService.instance.getRoomById(widget.receiverId);
      return _safeGroupRoomAvatarUrl(room);
    }
    return _safePersonHeaderAvatar(widget.avatarUrl);
  }

  bool _isKnownGroupConversationId(String value) {
    final id = value.trim();
    if (id.isEmpty || !id.startsWith('!')) return false;
    final room = MatrixChatService.instance.getRoomById(id);
    if (room != null) {
      return MatrixChatService.instance.isMatrixGroupRoom(room);
    }
    return _cachedConversationIsGroup(id);
  }

  String? _safeGroupRoomAvatarUrl(mx.Room? room) {
    final raw = room?.getState(mx.EventTypes.RoomAvatar)?.content['url'];
    final stateAvatar = raw is String ? raw.trim() : '';
    // Unjoined suggested rooms are not present in the client's synced room
    // list. Their public-directory avatar is still room-owned and arrives
    // already scoped to widget.conversationId by the discovery result.
    final avatar =
        stateAvatar.isNotEmpty
            ? stateAvatar
            : _isReadOnlySuggestedGroup
            ? widget.avatarUrl?.trim() ?? ''
            : '';
    if (avatar.isEmpty || _matchesGroupParticipantAvatar(room, avatar)) {
      return null;
    }
    return avatar;
  }

  bool _matchesGroupParticipantAvatar(mx.Room? room, String avatarUrl) {
    if (room == null) return false;
    final normalizedAvatar = _normaliseAvatarIdentity(avatarUrl);
    if (normalizedAvatar.isEmpty) return false;
    for (final member in room.getParticipants(_groupMemberships)) {
      if (member.id == MatrixClientService.instance.userId) continue;
      final memberAvatar = _normaliseAvatarIdentity(
        member.avatarUrl?.toString(),
      );
      if (memberAvatar.isNotEmpty && memberAvatar == normalizedAvatar) {
        return true;
      }
    }
    return false;
  }

  String _normaliseAvatarIdentity(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;
    if (uri.scheme == 'mxc') {
      return 'mxc://${uri.host}${uri.path}';
    }
    final segments = uri.pathSegments;
    final mediaIndex = segments.indexOf('media');
    if (mediaIndex >= 1 &&
        mediaIndex + 4 < segments.length &&
        segments[mediaIndex - 1] == '_matrix' &&
        segments[mediaIndex + 1] == 'v3' &&
        (segments[mediaIndex + 2] == 'download' ||
            segments[mediaIndex + 2] == 'thumbnail')) {
      final serverName = segments[mediaIndex + 3];
      final mediaId = segments.sublist(mediaIndex + 4).join('/');
      if (serverName.isNotEmpty && mediaId.isNotEmpty) {
        return 'mxc://$serverName/$mediaId';
      }
    }
    return trimmed;
  }

  String? _safePersonHeaderAvatar(String? avatarUrl) {
    final clean = avatarUrl?.trim() ?? '';
    // A person and a group may legitimately use the same image. Direct-chat
    // identity is already established by ConversationKind and receiver ID, so
    // rejecting a URL merely because it also appears on a room hides valid
    // contact avatars (for example in the header and profile entry point).
    if (clean.isEmpty) return null;
    return clean;
  }

  bool get _isReadOnlySuggestedGroup {
    if (!widget.readOnlyUntilJoin || _joinedSuggestedGroup) return false;
    final room = MatrixChatService.instance.getRoomById(_activeConversationId);
    return room == null || room.membership != mx.Membership.join;
  }

  bool get _isDeletedConversation =>
      _chat.isConversationDeleted(_activeConversationId) ||
      _messages.any(
        (message) => ChatService.isGroupDeletedPreview(message.content),
      );

  bool _cachedConversationIsGroup(String conversationId) {
    final room = MatrixChatService.instance.getRoomById(conversationId);
    if (room != null) {
      return MatrixChatService.instance.isMatrixGroupRoom(room);
    }
    final conversation = _chat.cachedConversationsSnapshot
        .where((item) => item.id == conversationId)
        .cast<ChatConversation?>()
        .firstWhere((item) => item != null, orElse: () => null);
    if (conversation == null) return false;
    if (conversation.hasExplicitKind) {
      return conversation.isGroupKind || conversation.isChannelKind;
    }
    if (conversation.lastMessageType == 'group' ||
        conversation.lastMessageType == ChatService.groupDeletedMessageType ||
        ChatService.isGroupDeletedPreview(conversation.lastMessage)) {
      return true;
    }
    return conversation.id.startsWith('!') &&
        conversation.participants.length > 2;
  }

  String get _activeConversationId =>
      (_resolvedConversationId?.trim().isNotEmpty == true)
          ? _resolvedConversationId!.trim()
          : widget.conversationId.trim();

  static const List<mx.Membership> _groupMemberships = [mx.Membership.join];

  Future<void> _loadGroupMemberProfiles(String roomId) async {
    final room = MatrixChatService.instance.getRoomById(roomId);
    final members = room?.getParticipants(_groupMemberships) ?? const [];
    _setGroupMembers(members);
    final resolutions = <Future<void>>[];
    for (final member in members) {
      final fallback = _cleanDisplayName(member.calcDisplayname());
      if (fallback.isNotEmpty && !_groupMemberNames.containsKey(member.id)) {
        _groupMemberNames[member.id] = fallback;
      }
      resolutions.add(_loadGroupMemberProfileName(member.id));
    }
    await Future.wait(resolutions);
    if (room != null) {
      unawaited(_requestFullGroupMemberList(room));
    }
    if (mounted) setState(() {});
  }

  Future<void> _primeGroupMemberProfiles(String roomId) async {
    await _loadGroupMemberProfiles(roomId);
    final senders = <String, ChatMessage>{};
    for (final message in _messages.followedBy(_initialStreamBuffer)) {
      final senderId = message.senderId.trim();
      if (senderId.isEmpty || senderId.startsWith('!') || _isMine(message)) {
        continue;
      }
      senders.putIfAbsent(senderId, () => message);
    }
    await Future.wait(
      senders.entries.map(
        (entry) => _loadGroupMemberProfileName(
          entry.key,
          phoneHint: entry.value.senderPhone,
        ),
      ),
    );
  }

  Future<void> _requestFullGroupMemberList(mx.Room room) async {
    try {
      final members = await room.requestParticipants(
        _groupMemberships,
        true,
        true,
      );
      if (!mounted) return;
      _setGroupMembers(members);
      for (final member in members) {
        final fallback = _cleanDisplayName(member.calcDisplayname());
        if (fallback.isNotEmpty && !_groupMemberNames.containsKey(member.id)) {
          _groupMemberNames[member.id] = fallback;
        }
        unawaited(_loadGroupMemberProfileName(member.id));
      }
      setState(() {});
    } catch (_) {
      // Keep the local Matrix member snapshot if the full request is unavailable.
    }
  }

  void _setGroupMembers(List<mx.User> members) {
    final seen = <String>{};
    final unique = <mx.User>[];
    for (final member in members) {
      if (seen.add(member.id)) unique.add(member);
    }
    _groupMembers = unique;
  }

  String _groupSenderName(String matrixId) {
    final resolved = _cleanDisplayName(_groupMemberNames[matrixId]);
    if (resolved.isNotEmpty) return resolved;
    for (final member in _groupMembers) {
      if (member.id != matrixId) continue;
      final fallback = _cleanDisplayName(member.calcDisplayname());
      if (fallback.isNotEmpty) return fallback;
    }
    return 'Group member';
  }

  Future<void> _loadGroupMemberProfileName(
    String matrixId, {
    String? phoneHint,
    bool forceRefresh = false,
  }) async {
    final senderId = matrixId.trim();
    if (senderId.isEmpty || senderId.startsWith('!')) {
      return;
    }
    if (!_groupSenderProfilesInFlight.add(senderId)) {
      if (forceRefresh) _pendingGroupMemberProfileRefreshes.add(senderId);
      return;
    }
    _pendingGroupMemberProfileRefreshes.remove(senderId);
    try {
      final localpart = _matrixLocalpart(senderId);
      if (localpart.isEmpty) return;
      final current = await AuthService.instance.getCurrentUserId();
      final isMe = _matrixLocalpart(current ?? '') == localpart;
      if (isMe) return;

      final ownerUserId = current?.trim() ?? '';
      final savedContact =
          ownerUserId.isEmpty
              ? null
              : await _findSavedContact(
                ownerUserId,
                senderId,
                phone: phoneHint,
              );
      if (savedContact != null && !forceRefresh) {
        final name = _cleanDisplayName(savedContact.formattedName);
        final avatar = savedContact.avatarUrl?.trim() ?? '';
        if (!mounted) return;
        setState(() {
          if (name.isNotEmpty) _groupMemberNames[senderId] = name;
          if (avatar.isNotEmpty) _groupMemberAvatars[senderId] = avatar;
        });
        return;
      }

      final localProfile1 =
          ownerUserId.isEmpty
              ? null
              : await ContactIdentityCache.instance.findByMatrixId(
                ownerUserId: ownerUserId,
                matrixUserId: senderId,
              );
      if (localProfile1 != null && !forceRefresh) {
        final name = _cleanDisplayName(localProfile1.profileName);
        final avatar = localProfile1.avatarUrl?.trim() ?? '';
        if (!mounted) return;
        setState(() {
          if (name.isNotEmpty) _groupMemberNames[senderId] = name;
          if (avatar.isNotEmpty) _groupMemberAvatars[senderId] = avatar;
        });
        return;
      }

      final profile = await UserProfileService.instance.getProfileByUid(
        localpart,
        phone: phoneHint,
        forceRefresh: forceRefresh,
      );
      if (profile?.moduleProfileLoaded == true &&
          (profile!.name.isEmpty || profile.name == profile.phone) &&
          savedContact == null) {
        _groupMemberNames.remove(senderId);
      }
      final name =
          forceRefresh && savedContact != null
              ? _cleanDisplayName(savedContact.formattedName)
              : _cleanDisplayName(profile?.displayName);
      final avatar =
          profile?.moduleProfileLoaded == true
              ? (profile!.hasProfileImage ? profile.profileImage : '')
              : profile?.profileImage.trim() ?? '';
      if (savedContact != null && profile?.moduleProfileLoaded == true) {
        final refreshedContact =
            await ContactLocalDb.refreshPublicProfileFields(
              ownerUserId: ownerUserId,
              wrytteUserId: senderId,
              phone: profile!.phone,
              avatarUrl: avatar,
              bio: profile.bio,
            );
        if (refreshedContact != null) {
          await ChatService().applySavedContact(refreshedContact);
        }
      }
      if (profile != null && ownerUserId.isNotEmpty) {
        await ContactIdentityCache.instance.upsert(
          ownerUserId: ownerUserId,
          matrixUserId: senderId,
          phone: profile.phone,
          profileName: name,
          avatarUrl: avatar,
          bio: profile.bio,
          clearAvatar: profile.moduleProfileLoaded && !profile.hasProfileImage,
          clearBio: profile.moduleProfileLoaded,
        );
      }
      if (!mounted) return;
      if (name.isEmpty && avatar.isEmpty) return;
      setState(() {
        if (name.isNotEmpty) _groupMemberNames[senderId] = name;
        if (avatar.isNotEmpty) _groupMemberAvatars[senderId] = avatar;
        if (avatar.isEmpty && profile?.moduleProfileLoaded == true) {
          _groupMemberAvatars.remove(senderId);
        }
      });
    } catch (_) {
      // Matrix display names are kept as fallback.
    } finally {
      _groupSenderProfilesInFlight.remove(senderId);
      if (_pendingGroupMemberProfileRefreshes.remove(senderId)) {
        unawaited(_loadGroupMemberProfileName(senderId, forceRefresh: true));
      }
    }
  }

  bool _isMine(ChatMessage message) {
    final current = widget.currentUserId.trim();
    final sender = message.senderId.trim();
    if (sender == current) return true;
    if (sender.startsWith('@') && sender.contains(':')) {
      return sender.substring(1, sender.indexOf(':')) == current;
    }
    return false;
  }

  String? _replySenderDisplayName(ChatMessage message) {
    final rawSender =
        message.replyToSenderId?.trim().isNotEmpty == true
            ? message.replyToSenderId!.trim()
            : _replySenderIdFromQuotedMessage(message);
    if (rawSender == null || rawSender.isEmpty) return null;

    if (_matrixLocalpart(rawSender) == _matrixLocalpart(widget.currentUserId)) {
      return 'You';
    }

    final receiverLocalpart = _matrixLocalpart(widget.receiverId);
    final senderLocalpart = _matrixLocalpart(rawSender);
    final isKnownPeer =
        senderLocalpart.isNotEmpty &&
        (senderLocalpart == receiverLocalpart ||
            senderLocalpart ==
                _matrixLocalpart(_receiverIdentity?.matrixUserId ?? ''));

    if (isKnownPeer) {
      final savedName = _cleanDisplayName(_receiverIdentity?.savedName);
      if (_receiverIsSavedContact && savedName.isNotEmpty) return savedName;

      final phone = _firstPhoneFrom([
        _receiverIdentity?.phone,
        _receiverProfile?.phone,
        widget.receiverId,
        widget.title,
        rawSender,
        ..._messagePeerIdentifiers(),
      ]);
      if (phone.isNotEmpty) return phone;

      final titleName = _cleanDisplayName(widget.title);
      if (titleName.isNotEmpty) return titleName;

      return null;
    }

    final phone = _firstPhoneFrom([rawSender]);
    if (phone.isNotEmpty) return phone;
    if (_looksLikeMatrixId(rawSender)) return null;

    final cleanName = _cleanDisplayName(rawSender);
    return cleanName.isNotEmpty ? cleanName : null;
  }

  String? _replySenderIdForOutgoingReply(ChatMessage? reply) {
    if (reply == null) return null;
    final sender = reply.senderId.trim();
    if (sender.isNotEmpty) return sender;
    return _isMine(reply) ? widget.currentUserId : widget.receiverId;
  }

  String? _replySenderIdFromQuotedMessage(ChatMessage message) {
    final replyToMessageId = message.replyToMessageId?.trim();
    if (replyToMessageId == null || replyToMessageId.isEmpty) return null;
    for (final candidate in _messages) {
      if (candidate.id != replyToMessageId) continue;
      final sender = candidate.senderId.trim();
      if (sender.isNotEmpty) return sender;
      return _isMine(candidate) ? widget.currentUserId : widget.receiverId;
    }
    return null;
  }

  String? _replyPreviewDisplayText(String? preview) {
    var text = preview?.trim() ?? '';
    if (text.isEmpty) return null;
    text = text.replaceFirst(RegExp(r'^<[^>]+>\s*'), '').trim();
    text =
        text.replaceFirst(RegExp(r'^@[A-Za-z0-9._=-]+:[^\s]+\s*'), '').trim();
    return text.isEmpty ? null : text;
  }

  String? _replyPreviewForMessage(ChatMessage message) {
    if (message.isDeleted) return 'This message was deleted';
    final attachmentType = message.attachmentType?.trim();
    if (attachmentType != null && attachmentType.isNotEmpty) {
      return _attachmentLabelForType(attachmentType);
    }
    final text = message.content.trim();
    if (text.isEmpty) return null;
    return text;
  }

  String _attachmentLabelForType(String type) {
    switch (type) {
      case 'image':
        return 'Photo';
      case 'video':
        return 'Video';
      case 'voice':
        return 'Voice';
      case 'file':
        return 'File';
      default:
        return 'Attachment';
    }
  }

  String? _firstLinkIn(String value) {
    final match = RegExp(
      r'((?:https?:\/\/|www\.)[^\s]+|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:\/[^\s]*)?)',
    ).firstMatch(value);
    final raw = match?.group(0);
    if (raw == null || raw.isEmpty) return null;
    return raw.replaceFirst(RegExp(r'[),.;:!?]+$'), '');
  }

  bool _isValidMatrixUserId(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith('@')) return false;
    if (trimmed.startsWith('@!')) return false;
    return trimmed.split(':').length == 2 && trimmed.split(':').last.isNotEmpty;
  }

  bool _isOwnMatrixId(String value) =>
      _matrixLocalpart(value) == _matrixLocalpart(widget.currentUserId);

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatDateDivider(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';

    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    if (diff > 1 && diff < 7) return weekdays[dt.weekday - 1];

    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final year = dt.year == now.year ? '' : ' ${dt.year}';
    return '${dt.day} ${months[dt.month - 1]}$year';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  ChatDeliveryState _mapDeliveryState(MessageStatus? status) {
    return switch (status) {
      MessageStatus.sending => ChatDeliveryState.pending,
      MessageStatus.sent => ChatDeliveryState.sent,
      MessageStatus.delivered => ChatDeliveryState.delivered,
      MessageStatus.read => ChatDeliveryState.read,
      MessageStatus.failed => ChatDeliveryState.failed,
      null => ChatDeliveryState.delivered,
    };
  }

  /// Do not show filenames / generic labels as captions.
  String? _imageCaption(String displayedContent) {
    final value = displayedContent.trim();
    if (value.isEmpty) return null;

    final lower = value.toLowerCase();
    if (const {'photo', 'image', 'attachment', 'photo message'}
        .contains(lower)) {
      return null;
    }
    if (RegExp(
      r'\.(png|jpe?g|gif|webp|bmp|heic|heif)$',
      caseSensitive: false,
    ).hasMatch(value)) {
      return null;
    }
    return value;
  }







  Widget _buildReplyComposerBanner() {
    final message = _replyingTo!;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF181B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF4DA3FF),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isMine(message) ? 'You' : widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9BD2FF),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _replyPreviewForMessage(message) ?? 'Message',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildEditComposerBanner() {
    final message = _editingMessage!;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF181B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF4DA3FF),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Edit Message',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF4DA3FF),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            onPressed: () {
              setState(() => _editingMessage = null);
              _controller.clear();
            },
          ),
        ],
      ),
    );
  }

  String? _effectiveAttachmentType(ChatMessage message) {
    final explicit = message.attachmentType?.trim().toLowerCase();
    if (explicit?.isNotEmpty == true) return explicit;

    final value =
        [
          message.attachmentUrl,
          message.content,
        ].whereType<String>().join(' ').toLowerCase();
    if (value.isEmpty) return null;

    if (RegExp(
      r'\.(png|jpe?g|gif|webp|bmp|heic|heif)(?:$|[?#\s])',
    ).hasMatch(value)) {
      return 'image';
    }
    if (RegExp(r'\.(mp4|mov|m4v|webm|mkv|3gp)(?:$|[?#\s])').hasMatch(value)) {
      return 'video';
    }
    if (RegExp(
      r'\.(pdf|docx?|pptx?|xlsx?|txt|csv|zip|rar|7z|apk)(?:$|[?#\s])',
    ).hasMatch(value)) {
      return 'file';
    }
    return null;
  }

  Widget _buildDateDivider(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: Colors.white.withValues(alpha: 0.08),
              height: 1,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(
              color: Colors.white.withValues(alpha: 0.08),
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassPill({
    required double width,
    required double height,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(color: const Color(0xFF23262C), width: 1.0),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 20, bottom: 5),
        child: Row(
          children: List<Widget>.generate(3, (index) {
            final start = index * 0.2;
            final end = (start + 0.45).clamp(0.0, 1.0);
            final animation = CurvedAnimation(
              parent: _controller,
              curve: Interval(start, end, curve: Curves.easeInOut),
            );
            return AnimatedBuilder(
              animation: animation,
              builder:
                  (context, child) => Opacity(
                    opacity: 0.35 + animation.value * 0.65,
                    child: child,
                  ),
              child: Container(
                width: 6,
                height: 6,
                margin: const EdgeInsetsDirectional.only(end: 4),
                decoration: const BoxDecoration(
                  color: Color(0xFF4EA1FF),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
