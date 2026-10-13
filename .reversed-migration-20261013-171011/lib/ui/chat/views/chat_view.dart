import 'dart:async';

import 'dart:io';

import 'dart:math' as math;

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart';

import 'package:flutter/services.dart';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:go_router/go_router.dart';

import 'package:provider/provider.dart';

import 'package:path_provider/path_provider.dart';

import 'package:wrytte/domain/models/attachment_gallery_config.dart';

import 'package:wrytte/domain/models/attachment_gallery_result.dart';

import 'package:wrytte/domain/models/camera_capture_result.dart';

import 'package:wrytte/domain/models/camera_session_config.dart';

import 'package:wrytte/domain/repositories/attachment_picker_repository.dart';

import 'package:wrytte/domain/repositories/camera_repository.dart';

import 'package:wrytte/domain/repositories/media_library_repository.dart';

import 'package:wrytte/routing/app_routes.dart';
import 'package:wrytte/ui/profile/models/profile_screen_data.dart';

import 'package:wrytte/ui/camera/views/wrytte_camera_route.dart';

import 'package:wrytte/ui/camera/widgets/attachment_camera_preview.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

import 'package:wrytte/ui/chat/models/chat_screen_config.dart';

import 'package:wrytte/ui/chat/models/chat_timeline_section.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';

import 'package:wrytte/ui/chat/view_models/chat_audio_playback_view_model.dart';

import 'package:wrytte/ui/chat/view_models/chat_selection_view_model.dart';

import 'package:wrytte/ui/chat/view_models/chat_video_playback_view_model.dart';

import 'package:wrytte/ui/chat/view_models/chat_view_model.dart';

import 'package:wrytte/ui/chat/widgets/chat_composer.dart';

import 'package:wrytte/ui/chat/widgets/chat_action_toast.dart';
import 'package:wrytte/ui/chat/widgets/chat_encryption_notice.dart';

import 'package:wrytte/ui/chat/widgets/chat_header.dart';

import 'package:wrytte/ui/chat/widgets/chat_header_backdrop.dart';

import 'package:wrytte/ui/chat/widgets/chat_layout_metrics.dart';

import 'package:wrytte/ui/chat/widgets/chat_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_action_menu.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';

import 'package:wrytte/ui/chat/widgets/chat_pinned_strip.dart';

import 'package:wrytte/ui/chat/widgets/selection/chat_message_selection_row.dart';

import 'package:wrytte/ui/chat/widgets/selection/chat_selection_header.dart';

import 'package:wrytte/ui/chat/views/chat_forward_sheet.dart';
import 'package:wrytte/ui/chat/views/pinned_messages_view.dart';
import 'package:wrytte/ui/core/routing/expanding_surface_route.dart';
import 'package:wrytte/ui/core/platform/keyboard_motion_bridge.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/core/widgets/wrytte_animated_popover.dart';

import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

import 'package:wrytte/ui/core/widgets/wrytte_glass_icon_button.dart';

import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

import 'package:wrytte/ui/media/views/attachment_gallery_sheet.dart';
import 'package:wrytte/ui/media/models/chat_media_editor_result.dart';
import 'package:wrytte/ui/media/views/chat_media_editor_view.dart';
import 'package:wrytte/ui/media/views/full_screen_video_view.dart';

enum _SelectionActionMenu { none, pin, delete }

class ChatView extends StatefulWidget {
  const ChatView({super.key});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _messageController = TextEditingController();

  final _messageFocusNode = FocusNode();

  // Places the viewport at the end during layout, before the first frame is
  // painted. This avoids opening at the top and visibly jumping or animating
  // through the conversation afterward.
  final _scrollController = ScrollController(keepScrollOffset: false);

  // Android 13+ already provides its own system clipboard confirmation.
  // Cache this decision so repeated copies do not query device info again.
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  bool? _showWrytteClipboardNotice;

  // Tracks pointers that STARTED on genuine empty conversation space.
  //
  // We do not dismiss the keyboard on pointer-down anymore. A pointer remains
  // a tap candidate only while it stays within Flutter's normal touch slop.
  // Once it moves farther than that, it is a scroll/drag and the keyboard stays
  // open.
  final Map<int, Offset> _emptyConversationTapOrigins = <int, Offset>{};

  // Keeps the scroll-to-latest control independent from the expensive chat
  // tree. Scroll notifications only rebuild this tiny floating control.
  final _scrollToLatestVisible = ValueNotifier<bool>(false);

  // Badge structure is already restored on the scroll control. Keep the count
  // at zero until unread-message integration supplies a real value.
  static const int _pendingNewMessageCount = 0;

  // Generation token lets a newer scroll-to-latest request cancel an older
  // one cleanly. A real user drag also cancels the programmatic chase.
  int _scrollToLatestGeneration = 0;
  bool _scrollToLatestInFlight = false;

  bool _recordingActive = false;
  final _fullScreenCameraOpen = ValueNotifier<bool>(false);

  final _selectionModel = ChatSelectionViewModel();

  // The message viewport now fills the whole screen so messages can scroll
  // completely behind the header. Date chips therefore use a visual overlay
  // instead of relying on the viewport's physical top for pinning.
  final _conversationViewportKey = GlobalKey();

  // The composer is painted OVER the full-height conversation viewport.
  // Keep its real laid-out height so the newest message can rest just above it
  // while older messages are still free to scroll underneath/behind it.
  double _composerOverlayHeight = 0;

  final Map<int, GlobalKey> _dateChipKeys = <int, GlobalKey>{};

  final ValueNotifier<_FloatingDateOverlayState> _floatingDateOverlay =
      ValueNotifier<_FloatingDateOverlayState>(
        const _FloatingDateOverlayState(),
      );

  bool _dateOverlayMeasurementScheduled = false;

  int? _activeDateSectionIndex;

  double _dateStickyTop = 0;

  List<String> _dateSectionLabels = const <String>[];

  // Inline date chips always remain visible. This notifier only controls a
  // date chip after it has detached from its natural timeline position.
  final _dateHeaderVisible = ValueNotifier<bool>(true);

  bool _dateHeaderPinnedAtVisualTop = false;

  // One video playback coordinator for this conversation.

  //

  // It owns at most one native player session.

  final _videoPlayback = ChatVideoPlaybackViewModel();

  Timer? _hintTimer;

  Timer? _dateHeaderHideTimer;

  OverlayEntry? _actionToastEntry;

  bool _recordHintVisible = false;

  bool _callMenuVisible = false;

  _SelectionActionMenu _selectionActionMenu = _SelectionActionMenu.none;

  // Retain the last menu's rows while its 190ms reverse animation runs.
  _SelectionActionMenu _selectionActionMenuContent =
      _SelectionActionMenu.delete;

  // One explicit offset animation owns the complete chat keyboard movement.
  // The composer and messages therefore always move from the same value.
  static const Duration _keyboardOpenDuration = Duration(milliseconds: 250);
  static const Duration _keyboardCloseDuration = Duration(milliseconds: 200);
  static const Duration _firstOpenLeadDuration = Duration(milliseconds: 64);
  static const double _firstOpenLeadTravel = 18.0;

  late final AnimationController _keyboardMotionController;

  // True while the chat is intentionally attached to an open/opening IME.
  bool _keyboardMotionActive = false;
  bool _keyboardOpening = false;

  // The largest destination requested during the current opening. Until a
  // native end bound is known, Flutter's real increasing viewInsets may only
  // move this target upward; they are never allowed to pull it back down.
  double _keyboardMotionTarget = 0;
  bool _keyboardTargetResolved = false;
  Stopwatch? _keyboardOpenStopwatch;

  // IME visibility is observed only for close detection and first-open fallback.
  bool _keyboardWasVisible = false;
  double _previousReportedKeyboardInset = 0;
  bool _systemKeyboardCloseStarted = false;

  // Once a real keyboard height has been observed, later openings can go
  // directly to the exact destination without any first-open discovery.
  double? _cachedKeyboardInset;
  double _latestReportedKeyboardInset = 0;
  Timer? _keyboardInsetSettleTimer;

  // Native Android IME animation bounds are the preferred first-open target.
  // If a device reports them late (or not at all), the small lead remains safe
  // and real increasing viewInsets take over instead of a guessed 300-400dp jump.
  StreamSubscription<KeyboardMotionTarget>? _keyboardMotionTargetSubscription;

  ChatMessagePresentation? _replyingTo;

  ChatMessagePresentation? _editingMessage;

  String? _editingMediaPath;

  bool _editingAsNewMedia = false;

  final Set<String> _pinnedMessageIds = <String>{};

  String? _dismissedPinnedStripSignature;

  // Reusable row keys let a pinned-strip tap bring an already-built message
  // precisely into view. A coarse seek is used first when the row is still
  // outside the lazy sliver build window.
  final Map<String, GlobalKey> _messageRowKeys = <String, GlobalKey>{};

  // Incrementing this token restarts the blue focus pulse even when the user
  // taps the same pinned message more than once.
  String? _pinnedHighlightMessageId;
  int _pinnedHighlightPulse = 0;

  // ===========================================================================

  // Lifecycle

  // ===========================================================================

  @override
  void initState() {
    super.initState();

    _keyboardMotionController = AnimationController.unbounded(
      vsync: this,
      value: 0,
    );

    WidgetsBinding.instance.addObserver(this);

    _messageFocusNode.addListener(_handleFocusChange);

    _keyboardMotionTargetSubscription = KeyboardMotionBridge.instance.targets
        .listen(_handleNativeKeyboardMotionTarget);

    _selectionModel.addListener(_handleSelectionChanged);
  }

  @override
  void dispose() {
    _hintTimer?.cancel();

    _dateHeaderHideTimer?.cancel();

    _keyboardInsetSettleTimer?.cancel();

    _keyboardMotionTargetSubscription?.cancel();

    _keyboardMotionController.dispose();

    _actionToastEntry?.remove();

    _actionToastEntry = null;

    WidgetsBinding.instance.removeObserver(this);

    _messageFocusNode.removeListener(_handleFocusChange);

    _selectionModel.removeListener(_handleSelectionChanged);

    // Releases the one possible native video session.

    _videoPlayback.dispose();

    _messageController.dispose();

    _messageFocusNode.dispose();

    _scrollController.dispose();

    _scrollToLatestVisible.dispose();

    _fullScreenCameraOpen.dispose();

    _selectionModel.dispose();

    _dateHeaderVisible.dispose();

    _floatingDateOverlay.dispose();

    super.dispose();
  }

  // ===========================================================================

  // Focus

  // ===========================================================================

  void _handleFocusChange() {
    final hasFocus = _messageFocusNode.hasFocus;

    if (hasFocus) {
      _hideTransientSurfaces();
      _systemKeyboardCloseStarted = false;

      if (!_keyboardMotionActive) {
        _beginKeyboardOpening();
      }
      return;
    }

    _beginKeyboardClosing();
  }

  void _beginKeyboardOpening() {
    if (!mounted || !_messageFocusNode.hasFocus) return;

    _keyboardInsetSettleTimer?.cancel();
    _keyboardMotionController.stop();

    _keyboardMotionActive = true;
    _keyboardOpening = true;
    _keyboardTargetResolved = false;
    _keyboardOpenStopwatch = Stopwatch()..start();

    final cachedKeyboardInset = _cachedKeyboardInset;
    if (cachedKeyboardInset != null && cachedKeyboardInset > 1.0) {
      _keyboardTargetResolved = true;
      _animateOpeningTo(
        math.max(0.0, cachedKeyboardInset - _stableSystemBottomInset()),
      );
      return;
    }

    // FIRST OPEN:
    // Start the Wrytte UI immediately, but only with a small visual lead. Never
    // launch toward a guessed full keyboard height. The native IME end bound or
    // real increasing Flutter viewInsets will extend this same motion afterward.
    final leadTarget = math.max(
      _keyboardMotionController.value,
      _firstOpenLeadTravel,
    );
    _keyboardMotionTarget = leadTarget;

    if (MediaQuery.disableAnimationsOf(context)) {
      _keyboardMotionController.value = leadTarget;
      return;
    }

    _keyboardMotionController.animateTo(
      leadTarget,
      duration: _firstOpenLeadDuration,
      curve: Curves.easeOutCubic,
    );
  }

  void _beginKeyboardClosing() {
    if (!mounted) return;

    _keyboardInsetSettleTimer?.cancel();
    _keyboardOpenStopwatch?.stop();
    _keyboardOpenStopwatch = null;
    _keyboardOpening = false;
    _keyboardTargetResolved = false;
    _keyboardMotionActive = false;
    _keyboardMotionTarget = 0;

    _keyboardMotionController.stop();

    if (MediaQuery.disableAnimationsOf(context)) {
      _keyboardMotionController.value = 0;
      return;
    }

    if (_keyboardMotionController.value <= .5) {
      _keyboardMotionController.value = 0;
      return;
    }

    _keyboardMotionController.animateTo(
      0,
      duration: _keyboardCloseDuration,
      curve: Curves.easeInCubic,
    );
  }

  double _stableSystemBottomInset() {
    final view = View.of(context);
    final devicePixelRatio = view.devicePixelRatio == 0
        ? 1.0
        : view.devicePixelRatio;
    return view.viewPadding.bottom / devicePixelRatio;
  }

  Duration _remainingOpeningDuration() {
    final elapsed = _keyboardOpenStopwatch?.elapsed ?? Duration.zero;
    final remainingMicros = math.max(
      0,
      _keyboardOpenDuration.inMicroseconds - elapsed.inMicroseconds,
    );
    return Duration(microseconds: remainingMicros);
  }

  void _animateOpeningTo(double requestedTravel) {
    if (!mounted ||
        !_messageFocusNode.hasFocus ||
        !_keyboardMotionActive ||
        !_keyboardOpening) {
      return;
    }

    final travel = math.max(0.0, requestedTravel);

    // Before the exact native end bound is known, fallback inset frames are
    // monotonic only: a late/smaller frame can never create an up/down wobble.
    final target = _keyboardTargetResolved
        ? travel
        : math.max(_keyboardMotionTarget, travel);

    if ((target - _keyboardMotionTarget).abs() < .5 &&
        (_keyboardMotionController.value - target).abs() < .5) {
      return;
    }

    _keyboardMotionTarget = target;
    _keyboardMotionController.stop();

    if (MediaQuery.disableAnimationsOf(context)) {
      _keyboardMotionController.value = target;
      return;
    }

    final remaining = _remainingOpeningDuration();

    // Normally the native target arrives near animation start, so the complete
    // opening remains 250ms from focus. On an unusually late OEM callback use a
    // tiny smoothing tail instead of snapping to the final position.
    final duration = remaining > Duration.zero
        ? remaining
        : const Duration(milliseconds: 32);

    _keyboardMotionController.animateTo(
      target,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  void _handleNativeKeyboardMotionTarget(KeyboardMotionTarget target) {
    if (!mounted || !target.visible) {
      // Closing is intentionally NOT driven by native visibility events. A late
      // hide callback from an older IME cycle must never reverse a new opening.
      return;
    }

    final view = View.of(context);
    final devicePixelRatio = view.devicePixelRatio == 0
        ? 1.0
        : view.devicePixelRatio;

    final logicalInset = switch (target.unit) {
      KeyboardMotionInsetUnit.physicalPixels => target.inset / devicePixelRatio,
      KeyboardMotionInsetUnit.logicalPixels => target.inset,
    };

    if (logicalInset > 1.0) {
      _cachedKeyboardInset = logicalInset;
      _latestReportedKeyboardInset = logicalInset;
    }

    if (!_messageFocusNode.hasFocus || !_keyboardOpening) return;

    // A native visible target is authoritative for this opening, including 0
    // for a floating/undocked keyboard that consumes no bottom edge.
    _keyboardTargetResolved = true;
    _animateOpeningTo(math.max(0.0, logicalInset - _stableSystemBottomInset()));
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;

    final view = View.of(context);
    final reportedInset = view.devicePixelRatio == 0
        ? 0.0
        : view.viewInsets.bottom / view.devicePixelRatio;

    final previousInset = _previousReportedKeyboardInset;
    final keyboardVisible = reportedInset > 1.0;
    final keyboardJustClosed = previousInset > 1.0 && !keyboardVisible;

    final keyboardStartedClosing =
        _keyboardMotionActive &&
        _messageFocusNode.hasFocus &&
        previousInset > 1.0 &&
        reportedInset < previousInset - 1.0;

    _previousReportedKeyboardInset = reportedInset;
    _keyboardWasVisible = keyboardVisible;

    if (keyboardVisible) {
      _latestReportedKeyboardInset = reportedInset;

      // FIRST-OPEN FALLBACK FOR LATE/ABSENT NATIVE TARGETS:
      // Follow only REAL upward IME measurements. There is no screen-percentage
      // keyboard guess anymore, so the composer cannot overshoot hundreds of dp.
      if (_messageFocusNode.hasFocus &&
          _keyboardOpening &&
          !_keyboardTargetResolved &&
          reportedInset > previousInset + .5) {
        final measuredTravel = math.max(
          0.0,
          reportedInset - _stableSystemBottomInset(),
        );
        if (measuredTravel > _keyboardMotionTarget + .5) {
          _animateOpeningTo(measuredTravel);
        }
      }

      _keyboardInsetSettleTimer?.cancel();
      _keyboardInsetSettleTimer = Timer(const Duration(milliseconds: 80), () {
        if (!mounted || !_messageFocusNode.hasFocus) return;

        final settledInset = _latestReportedKeyboardInset;
        if (settledInset <= 1.0) return;

        _cachedKeyboardInset = settledInset;

        // If this phone never supplied native animation bounds, the settled real
        // Flutter inset becomes the authoritative final target for THIS opening.
        if (_keyboardOpening && !_keyboardTargetResolved) {
          _keyboardTargetResolved = true;
          _animateOpeningTo(
            math.max(0.0, settledInset - _stableSystemBottomInset()),
          );
        }
      });
    } else {
      _keyboardInsetSettleTimer?.cancel();
      _latestReportedKeyboardInset = 0;
    }

    // Android back is detected from the first REAL downward inset frame. This
    // avoids stale native hide callbacks and gives every close the same 200ms path.
    if ((keyboardStartedClosing || keyboardJustClosed) &&
        !_systemKeyboardCloseStarted &&
        _messageFocusNode.hasFocus) {
      _systemKeyboardCloseStarted = true;
      _dismissComposerKeyboard();
    }
  }

  void _dismissComposerKeyboard() {
    if (_messageFocusNode.hasFocus) {
      _messageFocusNode.unfocus();
    }

    _hideTransientSurfaces();
  }

  bool get _composerKeyboardIsVisible =>
      _messageFocusNode.hasFocus ||
      _keyboardWasVisible ||
      View.of(context).viewInsets.bottom > 0;

  /// Shared result for:
  ///
  /// - a confirmed tap on empty conversation space
  /// - a confirmed tap on a TEXT message bubble
  ///
  /// It intentionally does nothing keyboard-related for scrolling, swiping,
  /// long-pressing, or taps on the other message kinds.
  void _handleConversationTap() {
    if (_composerKeyboardIsVisible) {
      _dismissComposerKeyboard();
      return;
    }

    _hideTransientSurfaces();
  }

  /// Empty-space detection uses raw pointer observation instead of another tap
  /// recognizer so it never competes with the message swipe, message long-press,
  /// media taps, or the Scrollable's vertical drag recognizer.
  void _handleConversationPointerDown(PointerDownEvent event) {
    // MessageSwipeActionTarget marks a pointer before this ancestor Listener
    // receives the same event. If it belongs to a real message bubble, it is
    // NEVER an empty-space tap candidate.
    if (MessageSwipeActionTarget.ownsPointer(event.pointer)) {
      return;
    }

    _emptyConversationTapOrigins[event.pointer] = event.position;
  }

  void _handleConversationPointerMove(PointerMoveEvent event) {
    final origin = _emptyConversationTapOrigins[event.pointer];
    if (origin == null) {
      return;
    }

    // Crossing normal Flutter touch slop means this interaction is a drag/
    // scroll, not a tap. Remove it immediately so pointer-up cannot close the
    // keyboard later.
    if ((event.position - origin).distance > kTouchSlop) {
      _emptyConversationTapOrigins.remove(event.pointer);
    }
  }

  void _handleConversationPointerUp(PointerUpEvent event) {
    final origin = _emptyConversationTapOrigins.remove(event.pointer);
    if (origin == null) {
      return;
    }

    _handleConversationTap();
  }

  void _handleConversationPointerCancel(PointerCancelEvent event) {
    _emptyConversationTapOrigins.remove(event.pointer);
  }

  void _handleSystemBack() {
    final keyboardVisible = View.of(context).viewInsets.bottom > 0;

    if (keyboardVisible || _messageFocusNode.hasFocus) {
      _dismissComposerKeyboard();
      return;
    }

    _handleBack();
  }

  void _handleComposerSize(Size size) {
    if (!mounted) return;

    final nextHeight = size.height;
    if ((_composerOverlayHeight - nextHeight).abs() < .5) return;

    setState(() => _composerOverlayHeight = nextHeight);
  }

  void _handleRecordingActiveChanged(bool active) {
    if (!mounted || _recordingActive == active) {
      return;
    }

    setState(() => _recordingActive = active);
  }

  void _handleSelectionChanged() {
    if (!mounted) {
      return;
    }

    setState(() {
      if (!_selectionModel.isSelectionMode) {
        _selectionActionMenu = _SelectionActionMenu.none;
      }
    });
  }

  // ===========================================================================

  // Transient UI

  // ===========================================================================

  void _hideTransientSurfaces() {
    _hintTimer?.cancel();

    if (!_recordHintVisible &&
        !_callMenuVisible &&
        _selectionActionMenu == _SelectionActionMenu.none) {
      return;
    }

    setState(() {
      _recordHintVisible = false;

      _callMenuVisible = false;

      _selectionActionMenu = _SelectionActionMenu.none;
    });
  }

  // ===========================================================================

  // Back

  // ===========================================================================

  void _handleBack() {
    if (_selectionActionMenu != _SelectionActionMenu.none) {
      setState(() => _selectionActionMenu = _SelectionActionMenu.none);

      return;
    }

    if (_selectionModel.isSelectionMode) {
      _selectionModel.clear();

      return;
    }

    if (_callMenuVisible || _recordHintVisible) {
      _hideTransientSurfaces();

      return;
    }

    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.welcome);
    }
  }

  // ===========================================================================

  // Header controls

  // ===========================================================================

  void _toggleCallMenu() {
    _hintTimer?.cancel();

    setState(() {
      _callMenuVisible = !_callMenuVisible;

      _recordHintVisible = false;
    });
  }

  void _toggleRecordMode() {
    context.read<ChatViewModel>().toggleRecordMode();

    _hintTimer?.cancel();

    setState(() {
      _callMenuVisible = false;

      _recordHintVisible = true;
    });

    _hintTimer = Timer(const Duration(milliseconds: 1750), () {
      if (!mounted) {
        return;
      }

      setState(() {
        _recordHintVisible = false;
      });
    });
  }

  // ===========================================================================

  // Sending

  // ===========================================================================

  void _send(String value) {
    final editing = _editingMessage;

    if (editing != null) {
      final chat = context.read<ChatViewModel>();
      final mediaPath = _editingMediaPath?.trim();

      if (_editingAsNewMedia &&
          editing.kind == ChatMessageKind.image &&
          mediaPath?.isNotEmpty == true) {
        chat.sendPreviewImage(mediaPath!, caption: value);
      } else if (_editingAsNewMedia &&
          editing.kind == ChatMessageKind.video &&
          mediaPath?.isNotEmpty == true) {
        chat.sendPreviewVideo(mediaPath!, caption: value);
      } else {
        chat.editPreviewMessage(editing.id, text: value, assetPath: mediaPath);
      }

      _clearEditingState();
      _scrollToLatest();
      return;
    }

    final reply = _replyingTo;

    context.read<ChatViewModel>().sendPreviewMessage(
      value,

      replySender: reply == null
          ? null
          : reply.isMine
          ? 'You'
          : (reply.senderName?.trim().isNotEmpty == true
                ? reply.senderName!.trim()
                : 'Wrytte Team'),

      replyPreview: reply == null ? null : _messagePreview(reply),
    );

    if (reply != null) {
      setState(() => _replyingTo = null);
    }

    _scrollToLatest();
  }

  void _clearEditingState() {
    if (!mounted) return;
    setState(() {
      _editingMessage = null;
      _editingMediaPath = null;
      _editingAsNewMedia = false;
    });
    _messageController.clear();
  }

  void _startEditingMessage(
    ChatMessagePresentation message, {
    String? mediaPath,
    bool asNewMedia = false,
  }) {
    final text = message.text?.trim() ?? '';
    setState(() {
      _replyingTo = null;
      _editingMessage = message;
      _editingMediaPath = mediaPath ?? message.assetPath;
      _editingAsNewMedia = asNewMedia;
    });
    _messageController
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    unawaited(_focusComposer());
  }

  Future<String?> _materializeEditableMedia(String source) async {
    final normalized = source.trim();
    if (normalized.isEmpty) return null;

    if (normalized.startsWith('assets/')) {
      final data = await rootBundle.load(normalized);
      final directory = await getTemporaryDirectory();
      final extension = normalized.split('.').last.toLowerCase();
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'wrytte_chat_edit_${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return file.path;
    }

    final uri = Uri.tryParse(normalized);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }

    final path = uri?.scheme == 'file' ? uri!.toFilePath() : normalized;
    return await File(path).exists() ? path : null;
  }

  Future<void> _editImageAsNewMedia(ChatMessagePresentation message) async {
    final source = message.assetPath?.trim() ?? '';
    if (source.isEmpty) return;

    try {
      final localPath = await _materializeEditableMedia(source);
      if (!mounted || localPath == null) {
        if (mounted) _showChatNotice('Could not open photo editor');
        return;
      }

      final repository = context.read<MediaLibraryRepository>();
      final result = await Navigator.of(context, rootNavigator: true)
          .push<ChatMediaEditorResult>(
            ExpandingSurfaceRoute<ChatMediaEditorResult>(
              animationsDisabled: MediaQuery.disableAnimationsOf(context),
              builder: (context, animation) => ChatMediaEditorView.file(
                path: localPath,
                repository: repository,
                width: message.mediaWidth ?? 0,
                height: message.mediaHeight ?? 0,
              ),
            ),
          );

      if (!mounted || result == null) return;
      _startEditingMessage(
        message,
        mediaPath: result.editedFilePath ?? result.originalFilePath,
        asNewMedia: true,
      );
    } catch (error, stackTrace) {
      debugPrint('Could not edit chat photo: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) _showChatNotice('Could not open photo editor');
    }
  }

  Future<void> _editVideoAsNewMedia(ChatMessagePresentation message) async {
    final source = message.assetPath?.trim() ?? '';
    if (source.isEmpty) return;

    try {
      final localPath = await _materializeEditableMedia(source);
      if (!mounted || localPath == null) {
        if (mounted) _showChatNotice('Could not open video editor');
        return;
      }

      var confirmed = false;
      await showWrytteVideoViewer(
        context,
        source: localPath,
        title: 'Edit video',
        subtitle: message.timeLabel,
        caption: message.text,
        onEdit: () {
          confirmed = true;
          Navigator.of(context, rootNavigator: true).pop();
        },
      );

      if (!mounted || !confirmed) return;
      _startEditingMessage(message, mediaPath: localPath, asNewMedia: true);
    } catch (error, stackTrace) {
      debugPrint('Could not edit chat video: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) _showChatNotice('Could not open video editor');
    }
  }

  // ===========================================================================

  // Attachments

  // ===========================================================================

  Future<void> _openAttachments() async {
    _messageFocusNode.unfocus();

    _hideTransientSurfaces();

    // Don't keep video playing underneath the attachment picker.

    await _videoPlayback.pause();

    if (!mounted) {
      return;
    }

    final mediaRepository = context.read<MediaLibraryRepository>();

    final cameraRepository = context.read<CameraRepository>();

    final pickerRepository = context.read<AttachmentPickerRepository>();

    const cameraConfig = CameraSessionConfig.chatAttachment();

    final resultFuture = showWrytteAttachmentGallery(
      context,

      config: const AttachmentGalleryConfig(
        purpose: AttachmentPurpose.chat,

        maxSelectionCount: 30,
      ),

      repository: mediaRepository,

      pickerRepository: pickerRepository,

      cameraPreviewBuilder: (_) {
        return AttachmentCameraPreview(
          repository: cameraRepository,

          fullScreenCameraOpen: _fullScreenCameraOpen,
        );
      },

      onCameraRequested: (origin, latestAsset) async {
        final thumbnail = latestAsset == null
            ? null
            : await mediaRepository.loadThumbnail(
                latestAsset.id,

                width: 160,

                height: 160,
              );

        if (!mounted) {
          return null;
        }

        _fullScreenCameraOpen.value = true;

        try {
          final result = await showWrytteCamera(
            context,

            repository: cameraRepository,

            config: cameraConfig,

            origin: origin,

            galleryThumbnail: thumbnail,

            returnToGallery: true,

            keepSessionAliveOnExit: true,
          );

          return result;
        } finally {
          if (mounted) {
            _fullScreenCameraOpen.value = false;
          }
        }
      },
    );

    unawaited(cameraRepository.open(cameraConfig));

    AttachmentGalleryResult? result;

    try {
      result = await resultFuture;
    } finally {
      await cameraRepository.close();
    }

    if (!mounted || result == null) {
      return;
    }

    if (_editingMessage != null) {
      await _replaceEditingMedia(result, mediaRepository);
      return;
    }

    await _addAttachmentResult(result, mediaRepository);
  }

  Future<void> _replaceEditingMedia(
    AttachmentGalleryResult result,
    MediaLibraryRepository mediaRepository,
  ) async {
    final editing = _editingMessage;
    if (editing == null) return;

    String? path;
    ChatMessageKind? replacementKind;

    final prepared = result.preparedFilePath?.trim();
    if (prepared?.isNotEmpty == true) {
      path = prepared;
      replacementKind = ChatMessageKind.image;
    } else if (result.assets.isNotEmpty) {
      final asset = result.assets.first;
      path = await mediaRepository.loadFilePath(asset.id);
      replacementKind = asset.kind.name == 'video'
          ? ChatMessageKind.video
          : ChatMessageKind.image;
    } else if (result.cameraCapture != null) {
      final capture = result.cameraCapture!;
      path = capture.path;
      replacementKind = capture.type == CameraMediaType.video
          ? ChatMessageKind.video
          : ChatMessageKind.image;
    }

    if (!mounted || path?.trim().isNotEmpty != true) return;
    if (replacementKind != editing.kind) {
      _showChatNotice(
        editing.kind == ChatMessageKind.video
            ? 'Choose a video replacement'
            : 'Choose a photo replacement',
      );
      return;
    }

    setState(() => _editingMediaPath = path!.trim());
    unawaited(_focusComposer());
  }

  Future<void> _addAttachmentResult(
    AttachmentGalleryResult result,

    MediaLibraryRepository mediaRepository,
  ) async {
    final chat = context.read<ChatViewModel>();

    final preparedPath = result.preparedFilePath?.trim();
    if (preparedPath?.isNotEmpty == true) {
      chat.sendPreviewImage(preparedPath!);
    }

    // -------------------------------------------------------------------------

    // Gallery assets

    // -------------------------------------------------------------------------

    for (final asset in result.assets) {
      final path = await mediaRepository.loadFilePath(asset.id);

      if (path == null) {
        continue;
      }

      if (asset.kind.name == 'image') {
        chat.sendPreviewImage(path);

        continue;
      }

      chat.sendPreviewVideo(path, durationSeconds: asset.duration.inSeconds);
    }

    // -------------------------------------------------------------------------

    // Camera

    // -------------------------------------------------------------------------

    final capture = result.cameraCapture;

    if (capture != null) {
      if (capture.type.name == 'photo') {
        chat.sendPreviewImage(capture.path);
      } else {
        chat.sendPreviewVideo(
          capture.path,

          durationSeconds: (capture.duration ?? Duration.zero).inSeconds,
        );
      }
    }

    // -------------------------------------------------------------------------

    // Files

    // -------------------------------------------------------------------------

    for (final file in result.files) {
      chat.sendPreviewFile(
        path: file.path,

        name: file.name,

        details: _fileSize(file.sizeBytes, file.extension),
      );
    }

    // -------------------------------------------------------------------------

    // Contacts

    // -------------------------------------------------------------------------

    for (final contact in result.contacts) {
      chat.sendPreviewContact(
        name: contact.displayName,

        phone: contact.phoneNumber,
      );
    }

    // -------------------------------------------------------------------------

    // Location

    // -------------------------------------------------------------------------

    if (result.locationLabel case final location?) {
      chat.sendPreviewMessage('Location: $location');
    }

    // -------------------------------------------------------------------------

    // Poll

    // -------------------------------------------------------------------------

    if (result.poll case final poll?) {
      final description = poll.description?.trim();

      chat.sendPreviewMessage(
        'Poll: ${poll.question}\n'
        '${description == null || description.isEmpty ? '' : '$description\n'}'
        '${poll.options.map((option) => '• $option').join('\n')}',
      );
    }

    _scrollToLatest();
  }

  String _fileSize(int bytes, String extension) {
    final size = bytes >= 1048576
        ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
        : '${(bytes / 1024).clamp(1, 9999).round()} KB';

    return extension.isEmpty ? size : '$size · $extension';
  }

  // ===========================================================================
  // Clipboard feedback
  // ===========================================================================

  /// Returns true when Wrytte should show its own copied-message notice.
  ///
  /// Android 13 / API 33 and newer already show a system clipboard overlay.
  /// Wrytte suppresses its own duplicate confirmation there.
  ///
  /// Android 12 and older keep Wrytte's confirmation. iOS and other supported
  /// platforms keep it too.
  Future<bool> _shouldShowWrytteClipboardNotice() async {
    final cached = _showWrytteClipboardNotice;
    if (cached != null) {
      return cached;
    }

    if (!Platform.isAndroid) {
      _showWrytteClipboardNotice = true;
      return true;
    }

    try {
      final androidInfo = await _deviceInfo.androidInfo;
      final shouldShow = androidInfo.version.sdkInt < 33;

      _showWrytteClipboardNotice = shouldShow;
      return shouldShow;
    } catch (error) {
      // Copying must still succeed if device inspection unexpectedly fails.
      // On Android, prefer avoiding a second confirmation over risking a
      // duplicate clipboard overlay.
      debugPrint('Could not resolve Android clipboard feedback policy: $error');

      _showWrytteClipboardNotice = false;
      return false;
    }
  }

  // ===========================================================================

  // Selection

  // ===========================================================================

  String _messagePreview(ChatMessagePresentation message) {
    final text = message.text?.trim();

    if (text != null && text.isNotEmpty) return text;

    final fileName = message.fileName?.trim();

    if (fileName != null && fileName.isNotEmpty) return fileName;

    return switch (message.kind) {
      ChatMessageKind.image => 'Photo',

      ChatMessageKind.video => message.isVideoNote ? 'Video message' : 'Video',

      ChatMessageKind.audio => 'Voice message',

      ChatMessageKind.file => 'File',

      ChatMessageKind.contact => message.contactName ?? 'Contact',

      ChatMessageKind.text => 'Message',
    };
  }

  void _showChatNotice(String message) {
    _actionToastEntry?.remove();

    late final OverlayEntry entry;

    entry = OverlayEntry(
      builder: (overlayContext) {
        final media = MediaQuery.of(overlayContext);

        final bottomObstruction = math.max(
          media.viewInsets.bottom,

          media.viewPadding.bottom,
        );

        return IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                left: 24,

                right: 24,

                bottom: 72 + bottomObstruction,

                child: ChatActionToast(
                  message: message,

                  onDismissed: () {
                    if (_actionToastEntry != entry) return;

                    entry.remove();

                    _actionToastEntry = null;
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    _actionToastEntry = entry;

    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _startReply(ChatMessagePresentation message) {
    _selectionModel.clear();

    setState(() {
      _replyingTo = message;
      _editingMessage = null;
      _editingMediaPath = null;
      _editingAsNewMedia = false;
    });

    unawaited(_focusComposer());
  }

  Future<void> _focusComposer() async {
    await WidgetsBinding.instance.endOfFrame;

    if (!mounted) return;

    _messageFocusNode.requestFocus();

    await WidgetsBinding.instance.endOfFrame;

    if (!mounted || !_messageFocusNode.hasFocus) return;

    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } on PlatformException catch (error) {
      debugPrint('Could not show chat keyboard: $error');
    }
  }

  List<ChatMessagePresentation> _pinnedMessages(ChatViewModel model) => [
    for (final message in model.messages)
      if (_pinnedMessageIds.contains(message.id)) message,
  ];

  // ---------------------------------------------------------------------------
  // Pinned-message in-chat navigation
  // ---------------------------------------------------------------------------

  GlobalKey _messageRowKeyFor(String messageId) {
    return _messageRowKeys.putIfAbsent(
      messageId,
      () => GlobalKey(debugLabel: 'chat-message-row-$messageId'),
    );
  }

  Future<bool> _ensurePinnedRowVisible(String messageId) async {
    final targetContext = _messageRowKeys[messageId]?.currentContext;

    if (targetContext == null) {
      return false;
    }

    await Scrollable.ensureVisible(
      targetContext,
      alignment: .45,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );

    return true;
  }

  Future<void> _scrollToPinnedMessage(
    ChatMessagePresentation target,
    List<ChatMessagePresentation> allMessages,
  ) async {
    if (!mounted) return;

    // Do not let a pending "scroll to latest" animation fight pinned-message
    // navigation.
    _scrollToLatestGeneration++;
    _scrollToLatestInFlight = false;

    // If Flutter already has this row mounted, use the real RenderObject
    // position immediately. This is the most accurate path.
    if (await _ensurePinnedRowVisible(target.id)) {
      return;
    }

    if (!_scrollController.hasClients || allMessages.isEmpty) {
      return;
    }

    final targetIndex = allMessages.indexWhere(
      (message) => message.id == target.id,
    );

    if (targetIndex < 0) {
      return;
    }

    final position = _scrollController.position;

    // The CustomScrollView is reversed:
    //
    //   minScrollExtent / 0 -> newest edge
    //   maxScrollExtent     -> older messages
    //
    // First seek close to the chronological location so the lazy sliver builds
    // the requested row.
    final denominator = math.max(1, allMessages.length - 1);

    final distanceFromNewest =
        (allMessages.length - 1 - targetIndex) / denominator;

    final coarseOffset =
        position.minScrollExtent +
        ((position.maxScrollExtent - position.minScrollExtent) *
            distanceFromNewest);

    await position.animateTo(
      coarseOffset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );

    await WidgetsBinding.instance.endOfFrame;

    if (!mounted || !_scrollController.hasClients) {
      return;
    }

    if (await _ensurePinnedRowVisible(target.id)) {
      return;
    }

    // Bubble heights vary, so the chronological ratio is only an estimate.
    // Use already-built rows as anchors and make a few small corrections until
    // the exact target enters the lazy sliver's build window.
    for (var attempt = 0; attempt < 4; attempt++) {
      int? nearestBuiltIndex;

      for (var index = 0; index < allMessages.length; index++) {
        final key = _messageRowKeys[allMessages[index].id];

        if (key?.currentContext == null) {
          continue;
        }

        if (nearestBuiltIndex == null ||
            (index - targetIndex).abs() <
                (nearestBuiltIndex - targetIndex).abs()) {
          nearestBuiltIndex = index;
        }
      }

      if (nearestBuiltIndex == null) {
        break;
      }

      final difference = nearestBuiltIndex - targetIndex;

      if (difference == 0) {
        break;
      }

      final currentPosition = _scrollController.position;

      // A lower chronological index is an older message and therefore sits
      // farther toward maxScrollExtent in this reversed viewport.
      final direction = difference > 0 ? 1.0 : -1.0;

      final estimatedTravel = (difference.abs() * 72.0)
          .clamp(140.0, currentPosition.viewportDimension * .82)
          .toDouble();

      final nextOffset =
          (currentPosition.pixels + (direction * estimatedTravel))
              .clamp(
                currentPosition.minScrollExtent,
                currentPosition.maxScrollExtent,
              )
              .toDouble();

      if ((nextOffset - currentPosition.pixels).abs() < .5) {
        break;
      }

      await currentPosition.animateTo(
        nextOffset,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );

      await WidgetsBinding.instance.endOfFrame;

      if (!mounted || !_scrollController.hasClients) {
        return;
      }

      if (await _ensurePinnedRowVisible(target.id)) {
        return;
      }
    }
  }

  void _pulsePinnedMessage(String messageId) {
    if (!mounted) return;

    setState(() {
      _pinnedHighlightMessageId = messageId;
      _pinnedHighlightPulse++;
    });
  }

  Future<void> _revealPinnedMessage(
    ChatMessagePresentation message,
    ChatViewModel model,
  ) async {
    await _scrollToPinnedMessage(message, model.messages);

    if (!mounted) {
      return;
    }

    _pulsePinnedMessage(message.id);
  }

  // ---------------------------------------------------------------------------
  // Pinned-message list
  // ---------------------------------------------------------------------------
  //
  // The strip BODY no longer calls this method.
  //
  // Only the explicit menu icon shown when there are multiple pinned messages
  // opens the dedicated pinned-messages screen.

  Future<void> _openPinnedMessages(
    ChatViewModel model,
    ChatAudioPlaybackViewModel audioPlayback,
  ) async {
    final pinned = _pinnedMessages(model);

    if (pinned.isEmpty) {
      return;
    }

    // Use a full-screen dialog route rather than a normal page route.
    //
    // Why:
    // A normal Navigator page can allow the route underneath to participate in
    // its platform page transition. That can make closing feel like the usual
    // horizontal back navigation even though this page itself entered from the
    // bottom.
    //
    // RawDialogRoute / showGeneralDialog keeps the chat underneath stationary
    // and gives this pinned view one authoritative transition:
    //
    //   open  : bottom -> screen
    //   close : screen -> bottom
    //
    // Navigator.pop() from the header, Android back, and "Unpin all" all drive
    // the SAME animation backwards.
    await showGeneralDialog<void>(
      context: context,

      // Put it above the chat navigator so the chat route itself does not run a
      // secondary left/right page transition underneath this surface.
      useRootNavigator: true,

      barrierDismissible: false,
      barrierLabel: 'Pinned messages',

      // The pinned page itself is full-screen/dark, but a small dark barrier
      // remains useful while the surface is moving on/off screen.
      barrierColor: Colors.black.withValues(alpha: .28),

      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 280),

      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return PinnedMessagesView(
          messages: pinned,
          audioPlayback: audioPlayback,
          videoPlayback: _videoPlayback,
          onBeforeVideoPlay: audioPlayback.stopAndClear,
          onActionSelected: _handleMessageAction,
          onReactionSelected: (message, reaction) {
            _showChatNotice('$reaction reaction added');
          },
          onUnpinAll: () {
            if (!mounted) {
              return;
            }

            setState(() {
              for (final message in pinned) {
                _pinnedMessageIds.remove(message.id);
              }
            });
          },
        );
      },

      transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
        // One vertical animation is used in BOTH directions.
        //
        // animation:
        //   push -> 0 to 1
        //   pop  -> 1 to 0
        //
        // Therefore this exact tween automatically becomes:
        //
        //   opening: Offset(0, 1) -> Offset.zero
        //   closing: Offset.zero  -> Offset(0, 1)
        final slideAnimation =
            Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
              CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ),
            );

        final fadeAnimation = Tween<double>(begin: .92, end: 1).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        );

        return SlideTransition(
          position: slideAnimation,
          child: FadeTransition(opacity: fadeAnimation, child: child),
        );
      },
    );

    if (mounted) {
      setState(() {});
    }
  }

  void _beginMessageSelection(ChatMessagePresentation message) {
    // Selection should freeze any inline video.

    unawaited(_videoPlayback.pause());

    _messageFocusNode.unfocus();

    _hideTransientSurfaces();

    unawaited(HapticFeedback.selectionClick());

    _selectionModel.select(message.id);
  }

  void _toggleMessageSelection(ChatMessagePresentation message) {
    unawaited(HapticFeedback.selectionClick());

    _selectionModel.toggle(message.id);
  }

  Future<void> _handleMessageAction(
    ChatMessagePresentation message,

    MessageAction action,
  ) async {
    switch (action.type) {
      case MessageActionType.reply:
        _startReply(message);

        return;

      case MessageActionType.copy:
        final value = _copyTextForMessage(message);

        if (value.isEmpty) return;

        await Clipboard.setData(ClipboardData(text: value));

        if (!mounted) return;

        if (await _shouldShowWrytteClipboardNotice() && mounted) {
          _showChatNotice('Message copied');
        }

        return;

      case MessageActionType.pin:
        setState(() {
          final pinned = _pinnedMessageIds.add(message.id);

          if (pinned) {
            // A newly pinned message should make the strip visible again even
            // if the previous pin set had been manually dismissed.
            _dismissedPinnedStripSignature = null;
          } else {
            _pinnedMessageIds.remove(message.id);
          }
        });

        _showChatNotice(
          _pinnedMessageIds.contains(message.id)
              ? 'Message pinned'
              : 'Message unpinned',
        );

        return;

      case MessageActionType.edit:
        _startEditingMessage(message);

        return;

      case MessageActionType.editMedia:
        if (message.kind == ChatMessageKind.image) {
          await _editImageAsNewMedia(message);
        } else if (message.kind == ChatMessageKind.video) {
          await _editVideoAsNewMedia(message);
        }

        return;

      case MessageActionType.delete:
        context.read<ChatViewModel>().removePreviewMessages([message.id]);

        setState(() {
          _pinnedMessageIds.remove(message.id);
        });

        _showChatNotice('Message deleted');

        return;

      case MessageActionType.select:
        _beginMessageSelection(message);

        return;

      case MessageActionType.forward:
        await _promptForwardMessages([message]);

        return;

      case MessageActionType.save:
        _showChatNotice('Saved');

        return;
    }
  }

  Future<bool> _promptForwardMessages(
    List<ChatMessagePresentation> messages,
  ) async {
    if (messages.isEmpty) {
      return false;
    }

    _messageFocusNode.unfocus();
    _hideTransientSurfaces();
    await _videoPlayback.pause();

    if (!mounted) {
      return false;
    }

    final previewText = messages.length == 1
        ? _copyTextForMessage(messages.single).trim()
        : '${messages.length} messages';

    final selectedTargets = await showWrytteChatForwardSheet(
      context,
      previewText: previewText.isEmpty ? 'Message' : previewText,
    );

    if (!mounted || selectedTargets == null || selectedTargets.isEmpty) {
      return false;
    }

    // Dummy forwarding for now. Replace this block with your real forwarding
    // service later; the picker already returns receiver/conversation fields.
    if (selectedTargets.length == 1) {
      _showChatNotice('Demo: forwarded to ${selectedTargets.first.title}');
    } else {
      _showChatNotice('Demo: forwarded to ${selectedTargets.length} contacts');
    }

    return true;
  }

  List<ChatMessagePresentation> _selectedMessages(ChatViewModel model) {
    return [
      for (final message in model.messages)
        if (_selectionModel.isSelected(message.id)) message,
    ];
  }

  String _copyTextForMessage(ChatMessagePresentation message) {
    final text = message.text?.trim() ?? '';

    if (text.isNotEmpty) {
      return text;
    }

    final fileName = message.fileName?.trim() ?? '';

    if (fileName.isNotEmpty) {
      return fileName;
    }

    return switch (message.kind) {
      ChatMessageKind.image => 'Photo',

      ChatMessageKind.video => 'Video',

      ChatMessageKind.audio => 'Voice message',

      ChatMessageKind.file => 'File',

      ChatMessageKind.contact => [
        message.contactName?.trim() ?? '',

        message.contactPhone?.trim() ?? '',
      ].where((value) => value.isNotEmpty).join('\n'),

      ChatMessageKind.text => '',
    };
  }

  Future<void> _copySelectedMessages(ChatViewModel model) async {
    final selected = _selectedMessages(model);

    final payload = selected
        .map(_copyTextForMessage)
        .where((value) => value.isNotEmpty)
        .join('\n');

    if (payload.isEmpty) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: payload));

    if (!mounted) {
      return;
    }

    _selectionModel.clear();

    if (await _shouldShowWrytteClipboardNotice() && mounted) {
      _showChatNotice(
        selected.length == 1 ? 'Message copied' : 'Messages copied',
      );
    }
  }

  void _pinSelectedMessages(
    List<ChatMessagePresentation> selectedMessages, {
    required bool forEveryone,
  }) {
    if (selectedMessages.isEmpty) {
      return;
    }

    setState(() {
      for (final message in selectedMessages) {
        _pinnedMessageIds.add(message.id);
      }

      _dismissedPinnedStripSignature = null;
    });

    final count = selectedMessages.length;
    _selectionModel.clear();
    _showChatNotice(
      count == 1
          ? forEveryone
                ? 'Message pinned for everyone'
                : 'Message pinned for me'
          : forEveryone
          ? '$count messages pinned for everyone'
          : '$count messages pinned for me',
    );
  }

  Future<void> _forwardSelectedMessages(
    List<ChatMessagePresentation> selectedMessages,
  ) async {
    final forwarded = await _promptForwardMessages(selectedMessages);

    if (forwarded && mounted) {
      _selectionModel.clear();
    }
  }

  List<MessageAction> _selectionDeleteActions(
    List<ChatMessagePresentation> selectedMessages,
  ) {
    final canDeleteForEveryone =
        selectedMessages.isNotEmpty &&
        selectedMessages.every((message) => message.isMine);

    return <MessageAction>[
      if (canDeleteForEveryone)
        const MessageAction(
          type: MessageActionType.delete,
          label: 'Delete for everyone',
          isDestructive: true,
        ),
      const MessageAction(
        type: MessageActionType.delete,
        label: 'Delete for me',
        isDestructive: true,
      ),
      const MessageAction(type: MessageActionType.delete, label: 'Cancel'),
    ];
  }

  List<MessageAction> _selectionPinActions() {
    return const <MessageAction>[
      MessageAction(type: MessageActionType.pin, label: 'Pin for everyone'),
      MessageAction(type: MessageActionType.pin, label: 'Pin for me'),
      MessageAction(type: MessageActionType.pin, label: 'Cancel'),
    ];
  }

  Future<void> _handleSelectionPinAction(
    ChatViewModel model,
    MessageAction action,
  ) async {
    if (action.label == 'Cancel') {
      setState(() => _selectionActionMenu = _SelectionActionMenu.none);
      return;
    }

    final selectedMessages = _selectedMessages(model);

    if (selectedMessages.isEmpty) {
      setState(() => _selectionActionMenu = _SelectionActionMenu.none);
      return;
    }

    final forEveryone = action.label == 'Pin for everyone';
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    setState(() => _selectionActionMenu = _SelectionActionMenu.none);

    if (!reduceMotion) {
      await Future<void>.delayed(const Duration(milliseconds: 190));
    }

    if (!mounted) {
      return;
    }

    _pinSelectedMessages(selectedMessages, forEveryone: forEveryone);
  }

  Future<void> _handleSelectionDeleteAction(
    ChatViewModel model,
    MessageAction action,
  ) async {
    if (action.label == 'Cancel') {
      setState(() => _selectionActionMenu = _SelectionActionMenu.none);
      return;
    }

    final selectedMessages = _selectedMessages(model);
    final deleteForEveryone = action.label == 'Delete for everyone';

    if (selectedMessages.isEmpty ||
        (deleteForEveryone &&
            !selectedMessages.every((message) => message.isMine))) {
      setState(() => _selectionActionMenu = _SelectionActionMenu.none);
      return;
    }

    final ids = selectedMessages.map((message) => message.id).toSet();
    final count = ids.length;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    // Let the confirmation surface perform the same reverse collapse used by
    // the full-screen profile/photo delete control before rows are removed.
    setState(() => _selectionActionMenu = _SelectionActionMenu.none);

    if (!reduceMotion) {
      await Future<void>.delayed(const Duration(milliseconds: 190));
    }

    if (!mounted) {
      return;
    }

    model.removePreviewMessages(ids);

    setState(() {
      _pinnedMessageIds.removeAll(ids);
    });

    _selectionModel.clear();
    _showChatNotice(
      count == 1
          ? deleteForEveryone
                ? 'Message deleted for everyone'
                : 'Message deleted for me'
          : deleteForEveryone
          ? '$count messages deleted for everyone'
          : '$count messages deleted for me',
    );
  }

  // ===========================================================================

  // Scrolling

  // ===========================================================================

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }

    _updateScrollToLatestVisibility(notification.metrics);

    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // Never let a programmatic bottom chase fight a deliberate user drag.
      if (_scrollToLatestInFlight) {
        _scrollToLatestGeneration++;
        _scrollToLatestInFlight = false;
      }
    }

    _dateHeaderPinnedAtVisualTop =
        notification.metrics.pixels >=
        notification.metrics.maxScrollExtent - .75;

    if (notification is ScrollStartNotification) {
      unawaited(_videoPlayback.pause());
      _showDateHeaderWhileScrolling();
    } else if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      // Keep the detached helper visible for the entire gesture / fling.
      _showDateHeaderWhileScrolling();
    } else if (notification is ScrollEndNotification) {
      _dateHeaderHideTimer?.cancel();
      _scheduleDateOverlayMeasurement();

      if (_dateHeaderPinnedAtVisualTop) {
        // At the visual start, the first divider is effectively still in its
        // real timeline position, so keep it visible.
        if (!_dateHeaderVisible.value) {
          _dateHeaderVisible.value = true;
        }
      } else {
        // Old Wrytte behavior: when scrolling stops away from the top, the
        // detached date helper hangs around briefly, then fades away.
        _dateHeaderHideTimer = Timer(const Duration(milliseconds: 180), () {
          if (!mounted || _dateHeaderPinnedAtVisualTop) {
            return;
          }

          _dateHeaderVisible.value = false;
        });
      }
    }

    return false;
  }

  bool _handleScrollMetricsNotification(
    ScrollMetricsNotification notification,
  ) {
    if (notification.depth != 0) {
      return false;
    }

    // Keyboard opening/closing and composer growth change the viewport without
    // being a user scroll. Refresh geometry, but NEVER change the user's
    // scroll offset or jump them to the latest message.
    _updateScrollToLatestVisibility(notification.metrics);
    _dateHeaderPinnedAtVisualTop =
        notification.metrics.pixels >=
        notification.metrics.maxScrollExtent - .75;
    _scheduleDateOverlayMeasurement();

    return false;
  }

  void _updateScrollToLatestVisibility(ScrollMetrics metrics) {
    // A sub-pixel threshold made the control appear as soon as the list moved
    // at all. Keep a real near-latest zone so the newest messages travel a
    // useful distance first, matching the old Wrytte behavior and established
    // chat-app timing. The smaller return threshold adds hysteresis, preventing
    // the control from flickering around one exact boundary during a settle.
    const revealDistance = 80.0;
    const hideDistance = 40.0;

    final isScrollable = metrics.maxScrollExtent > metrics.minScrollExtent;
    final distanceFromLatest = metrics.extentBefore;
    final currentlyVisible = _scrollToLatestVisible.value;

    final shouldShow =
        isScrollable &&
        distanceFromLatest > (currentlyVisible ? hideDistance : revealDistance);

    if (currentlyVisible != shouldShow) {
      _scrollToLatestVisible.value = shouldShow;
    }
  }

  void _showDateHeaderWhileScrolling() {
    _dateHeaderHideTimer?.cancel();

    if (!_dateHeaderVisible.value) {
      _dateHeaderVisible.value = true;
    }

    _scheduleDateOverlayMeasurement();
  }

  GlobalKey _dateChipKeyFor(int sectionIndex) {
    return _dateChipKeys.putIfAbsent(
      sectionIndex,
      () => GlobalKey(debugLabel: 'chat-date-chip-$sectionIndex'),
    );
  }

  void _scheduleDateOverlayMeasurement() {
    if (_dateOverlayMeasurementScheduled) {
      return;
    }

    _dateOverlayMeasurementScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dateOverlayMeasurementScheduled = false;

      if (!mounted) {
        return;
      }

      _measureDateOverlay();
    });
  }

  void _measureDateOverlay() {
    if (_dateSectionLabels.isEmpty) {
      if (_floatingDateOverlay.value.hasDate) {
        _floatingDateOverlay.value = const _FloatingDateOverlayState();
      }
      return;
    }

    final viewportObject = _conversationViewportKey.currentContext
        ?.findRenderObject();

    if (viewportObject is! RenderBox ||
        !viewportObject.attached ||
        !viewportObject.hasSize) {
      return;
    }

    final stickyTop = _dateStickyTop;

    final measured = <_MeasuredDateChip>[];

    for (final entry in _dateChipKeys.entries) {
      final sectionIndex = entry.key;

      if (sectionIndex < 0 || sectionIndex >= _dateSectionLabels.length) {
        continue;
      }

      final context = entry.value.currentContext;
      final renderObject = context?.findRenderObject();

      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        continue;
      }

      final topLeft = renderObject.localToGlobal(
        Offset.zero,
        ancestor: viewportObject,
      );

      measured.add(
        _MeasuredDateChip(
          sectionIndex: sectionIndex,
          top: topLeft.dy,
          bottom: topLeft.dy + renderObject.size.height,
        ),
      );
    }

    measured.sort((a, b) => a.sectionIndex.compareTo(b.sectionIndex));

    var activeIndex = _activeDateSectionIndex;

    // At the visual beginning the first date owns the conversation.
    if (_dateHeaderPinnedAtVisualTop) {
      activeIndex = 0;
    } else {
      // The first date chip still below the sticky line belongs to the NEXT
      // section. The active section is therefore the one immediately before it.
      _MeasuredDateChip? firstBelowSticky;

      for (final chip in measured) {
        if (chip.top > stickyTop + .5) {
          if (firstBelowSticky == null || chip.top < firstBelowSticky.top) {
            firstBelowSticky = chip;
          }
        }
      }

      if (firstBelowSticky != null) {
        activeIndex = math.max(0, firstBelowSticky.sectionIndex - 1);
      } else {
        // If the latest visible divider has already crossed the sticky line,
        // it becomes active.
        for (final chip in measured) {
          if (chip.top <= stickyTop + .5) {
            activeIndex = chip.sectionIndex;
          }
        }

        // On an initial jump directly to the latest messages, the latest
        // divider may already be outside the lazy-build window. In that case
        // the newest section is the correct fallback.
        if (activeIndex == null &&
            _scrollController.hasClients &&
            _scrollController.position.extentBefore <= 1.0) {
          activeIndex = _dateSectionLabels.length - 1;
        }
      }
    }

    activeIndex ??= _dateHeaderPinnedAtVisualTop
        ? 0
        : _dateSectionLabels.length - 1;

    activeIndex = activeIndex.clamp(0, _dateSectionLabels.length - 1);

    _activeDateSectionIndex = activeIndex;

    const chipHeight = 23.0;
    const collisionGap = 2.0;
    const handoffExtent = chipHeight + collisionGap;

    double outgoingOffset = 0;

    final nextIndex = activeIndex + 1;

    if (nextIndex < _dateSectionLabels.length) {
      _MeasuredDateChip? nextChip;

      for (final chip in measured) {
        if (chip.sectionIndex == nextIndex) {
          nextChip = chip;
          break;
        }
      }

      if (nextChip != null) {
        final distanceToSticky = nextChip.top - stickyTop;

        if (distanceToSticky < handoffExtent) {
          outgoingOffset = (distanceToSticky - handoffExtent)
              .clamp(-handoffExtent, 0.0)
              .toDouble();
        }
      }
    }

    // Do not let the floating overlay steal the date the instant scrolling
    // starts. The inline chip may still be visibly below the sticky position,
    // and replacing it immediately would make the date jump upward.
    //
    // The overlay takes ownership only when the REAL active date chip has
    // physically reached (or crossed) the sticky Y coordinate. If that chip is
    // no longer mounted because it has already scrolled outside the lazy-build
    // window, it is necessarily detached and the overlay should own it.
    _MeasuredDateChip? activeChip;

    for (final chip in measured) {
      if (chip.sectionIndex == activeIndex) {
        activeChip = chip;
        break;
      }
    }

    final ownsInlineDate = activeChip == null
        ? !_dateHeaderPinnedAtVisualTop
        : activeChip.top <= stickyTop + .5;

    final nextState = _FloatingDateOverlayState(
      sectionIndex: activeIndex,
      label: _dateSectionLabels[activeIndex],
      outgoingOffsetY: outgoingOffset,
      ownsInlineDate: ownsInlineDate,
    );

    final current = _floatingDateOverlay.value;

    final unchanged =
        current.sectionIndex == nextState.sectionIndex &&
        current.label == nextState.label &&
        current.ownsInlineDate == nextState.ownsInlineDate &&
        (current.outgoingOffsetY - nextState.outgoingOffsetY).abs() < .01;

    if (!unchanged) {
      _floatingDateOverlay.value = nextState;
    }
  }

  void _scrollToLatest() {
    final generation = ++_scrollToLatestGeneration;
    unawaited(_scrollToLatestCompletely(generation));
  }

  Future<void> _scrollToLatestCompletely(int generation) async {
    _scrollToLatestInFlight = true;

    try {
      // Give pending message/composer state one frame to enter the sliver
      // layout before reading the latest edge for the first time.
      await WidgetsBinding.instance.endOfFrame;

      if (!mounted ||
          generation != _scrollToLatestGeneration ||
          !_scrollController.hasClients) {
        return;
      }

      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      var stableBottomChecks = 0;

      // Bounded chase: each pass re-reads the CURRENT latest edge.
      //
      // This is what prevents the button from stopping halfway when the
      // timeline grows during the original animation.
      for (var pass = 0; pass < 10; pass++) {
        if (!mounted ||
            generation != _scrollToLatestGeneration ||
            !_scrollController.hasClients) {
          return;
        }

        final position = _scrollController.position;
        final target = position.minScrollExtent;
        final remaining = target - position.pixels;

        if (remaining.abs() > .75) {
          stableBottomChecks = 0;

          if (reduceMotion) {
            _scrollController.jumpTo(target);
          } else {
            // Longer distances get a little more time, but the control still
            // feels immediate and never turns into a slow multi-second glide.
            final distance = remaining.abs();
            final milliseconds = (190 + (distance * .12)).round().clamp(
              190,
              360,
            );

            await _scrollController.animateTo(
              target,
              duration: Duration(milliseconds: milliseconds),
              curve: Curves.easeOutCubic,
            );
          }
        } else {
          // Snap away fractional residue so "latest" is exact.
          if ((position.pixels - target).abs() > .01) {
            _scrollController.jumpTo(target);
          }
          stableBottomChecks++;
        }

        // Let Flutter complete layout/paint and also catch a late extent change
        // from newly inserted content or media sizing.
        await WidgetsBinding.instance.endOfFrame;

        if (!mounted ||
            generation != _scrollToLatestGeneration ||
            !_scrollController.hasClients) {
          return;
        }

        if (_scrollController.position.extentBefore <= .75) {
          stableBottomChecks++;
        } else {
          stableBottomChecks = 0;
        }

        // Two consecutive bottom confirmations means the final message really
        // is at the latest position, not merely at an outdated target.
        if (stableBottomChecks >= 2) {
          _scrollToLatestVisible.value = false;
          return;
        }

        // A tiny settle window catches extent changes that land just after the
        // animation/frame boundary without making the interaction feel delayed.
        await Future<void>.delayed(const Duration(milliseconds: 36));
      }

      // Final hard guarantee after the bounded chase.
      if (mounted &&
          generation == _scrollToLatestGeneration &&
          _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.minScrollExtent);
        _scrollToLatestVisible.value = false;
      }
    } finally {
      if (generation == _scrollToLatestGeneration) {
        _scrollToLatestInFlight = false;
      }
    }
  }

  Widget _buildNewMessagesBadge() {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      height: 1,
    );
    final label = _pendingNewMessageCount > 99
        ? '99+'
        : '$_pendingNewMessageCount';
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final diameter = math.max(22.0, painter.width + 12).toDouble();
    painter.dispose();

    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: WrytteColors.primary,
        shape: BoxShape.circle,
      ),
      child: Text(label, textAlign: TextAlign.center, style: style),
    );
  }

  Widget _buildScrollToLatestControl(
    ChatLayoutMetrics metrics, {
    required bool available,
  }) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return ValueListenableBuilder<bool>(
      valueListenable: _scrollToLatestVisible,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          WrytteGlassIconButton(
            semanticLabel: _pendingNewMessageCount > 0
                ? '$_pendingNewMessageCount new messages, scroll to latest'
                : 'Scroll to latest message',
            onPressed: _scrollToLatest,
            // This is the same authoritative size used by the idle voice/video
            // recording-mode button in ChatComposer.
            size: ChatComposer.controlSize,
            child: Transform.translate(
              // Small optical correction after rotating the back-chevron.
              offset: Offset(0, 1 * metrics.scale),
              child: RotatedBox(
                quarterTurns: -1,
                child: WrytteSvgIcon(
                  asset: 'assets/svg/ic--round-arrow-back-ios.svg',
                  size: 25 * metrics.scale,
                  color: WrytteColors.textPrimary,
                ),
              ),
            ),
          ),
          // Restored from old Wrytte and intentionally dormant until unread
          // message counting is integrated.
          if (_pendingNewMessageCount > 0)
            Positioned(
              top: -13,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: _buildNewMessagesBadge(),
              ),
            ),
        ],
      ),
      builder: (context, visible, child) {
        final effectiveVisible = visible && available;
        final duration = reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 150);

        return IgnorePointer(
          ignoring: !effectiveVisible,
          child: AnimatedOpacity(
            opacity: effectiveVisible ? 1 : 0,
            duration: duration,
            curve: effectiveVisible ? Curves.easeOutCubic : Curves.easeInCubic,
            child: AnimatedSlide(
              offset: effectiveVisible ? Offset.zero : const Offset(0, .30),
              duration: duration,
              curve: Curves.easeOutCubic,
              child: AnimatedScale(
                scale: effectiveVisible ? 1 : .72,
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: effectiveVisible
                    ? Curves.easeOutBack
                    : Curves.easeInCubic,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================

  // Build

  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ChatViewModel>();

    final metrics = ChatLayoutMetrics.of(context);

    final timelineSections = buildChatTimelineSections(model.messages);

    final audioPlayback = context.read<ChatAudioPlaybackViewModel>();

    // viewPadding is stable while the keyboard animates. Using padding here
    // would make this large ChatView rebuild as bottom padding is consumed by
    // the IME, even though we only need the unchanged top system inset.
    final topInset = MediaQuery.viewPaddingOf(context).top;

    final headerExtent = topInset + metrics.headerHeight;

    final headerPillBottom =
        topInset +
        ((metrics.headerHeight - metrics.controlSize) / 2) +
        metrics.controlSize;

    final headerOverlayHeight = headerPillBottom + 24;

    final popoverTop = topInset + metrics.headerHeight + 4;

    final navigationInset = MediaQuery.viewPaddingOf(context).bottom;

    // Before the first measurement use the known one-line composer minimum so
    // the first frame does not place the latest bubble underneath the composer.
    // After layout, the measured value automatically follows multiline/reply/
    // edit/recording composer heights.
    final composerOverlayExtent = _composerOverlayHeight > .5
        ? _composerOverlayHeight
        : ChatComposer.controlSize + navigationInset + 6.0;

    final composerBottomFloatGap = navigationInset > 0 ? 10.0 : 12.0;
    const composerTopPadding = 8.0;
    const scrollControlToRecorderGap = 4.0;
    final scrollToLatestControlBottom =
        composerBottomFloatGap +
        composerTopPadding +
        ChatComposer.controlSize +
        scrollControlToRecorderGap;

    final selectionMode = _selectionModel.isSelectionMode;

    final selectedMessages = _selectedMessages(model);

    final selectionMenuActions = switch (_selectionActionMenuContent) {
      _SelectionActionMenu.pin => _selectionPinActions(),
      _SelectionActionMenu.delete => _selectionDeleteActions(selectedMessages),
      _SelectionActionMenu.none => _selectionDeleteActions(selectedMessages),
    };

    final selectionMenuHeight = MessageActionMenu.naturalHeightFor(
      selectionMenuActions.length,
    );

    final selectionMenuWidth = MessageActionMenu.widthFor(
      context,
      actions: selectionMenuActions,
      availableWidth:
          MediaQuery.sizeOf(context).width - (metrics.horizontalPadding * 2),
    );

    final selectionActionPillEnd =
        metrics.horizontalPadding +
        metrics.controlSize +
        metrics.controlGap +
        ChatSelectionHeader.actionPillWidth(context);

    final selectionMenuEnd = math
        .max(
          metrics.horizontalPadding,
          MediaQuery.sizeOf(context).width - selectionActionPillEnd,
        )
        .toDouble();

    final pinnedMessages = _pinnedMessages(model);

    final pinnedSignature = pinnedMessages
        .map((message) => message.id)
        .join('\u0000');

    final showPinnedStrip =
        pinnedMessages.isNotEmpty &&
        _dismissedPinnedStripSignature != pinnedSignature;

    _dateStickyTop =
        headerExtent + (showPinnedStrip ? ChatPinnedStrip.extent : 0.0) + 4.0;

    _dateSectionLabels = <String>[
      for (final section in timelineSections) section.label,
    ];

    _dateChipKeys.removeWhere((index, key) => index >= timelineSections.length);

    if (_activeDateSectionIndex == null && timelineSections.isNotEmpty) {
      _activeDateSectionIndex = timelineSections.length - 1;
    }

    _scheduleDateOverlayMeasurement();

    // Keyboard motion is driven by one explicit controller. The first open may
    // extend upward from real IME measurements, but it never uses a guessed
    // full keyboard height or starts a second implicit animation.

    return PopScope(
      canPop: false,

      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleSystemBack();
        }
      },

      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,

          statusBarIconBrightness: Brightness.light,

          statusBarBrightness: Brightness.dark,

          systemNavigationBarColor: Colors.transparent,

          systemNavigationBarDividerColor: Colors.transparent,

          systemNavigationBarIconBrightness: Brightness.light,

          systemNavigationBarContrastEnforced: false,
        ),

        child: Scaffold(
          backgroundColor: WrytteColors.background,

          extendBody: true,

          // The chat owns its keyboard transition. Scaffold resizing stays off so
          // the system IME cannot apply a second movement on top of our own
          // 250ms opening / 200ms closing animation.
          resizeToAvoidBottomInset: false,

          body: Stack(
            children: [
              const Positioned.fill(child: _ChatBackdrop()),

              // The conversation and composer share one keyboard-motion boundary,
              // so they always travel from the same explicit animated offset. Inside that boundary
              // the conversation fills the area and the composer paints above it, which
              // lets scrolled bubbles remain visible behind the glass composer.
              Positioned.fill(
                child: _KeyboardMotionBoundary(
                  offset: _keyboardMotionController,
                  child: Stack(
                    children: [
                      // The conversation viewport fills the complete chat area,
                      // including the pixels physically behind the composer.
                      // The composer is painted later as an overlay instead of
                      // shortening this viewport.
                      Positioned.fill(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            SizedBox.expand(
                              key: _conversationViewportKey,
                              child: Listener(
                                behavior: HitTestBehavior.translucent,
                                // Empty conversation space dismisses the keyboard only
                                // after a REAL tap. Pointer movement beyond touch slop
                                // cancels the candidate, so vertical scrolling keeps the
                                // keyboard open.
                                //
                                // Pointers that begin on a message bubble are excluded by
                                // MessageSwipeActionTarget and keep their own tap / swipe /
                                // long-press behavior.
                                onPointerDown: _handleConversationPointerDown,
                                onPointerMove: _handleConversationPointerMove,
                                onPointerUp: _handleConversationPointerUp,
                                onPointerCancel:
                                    _handleConversationPointerCancel,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: _hideTransientSurfaces,
                                  child: NotificationListener<ScrollMetricsNotification>(
                                    onNotification:
                                        _handleScrollMetricsNotification,
                                    child: NotificationListener<ScrollNotification>(
                                      onNotification: _handleScrollNotification,
                                      child: CustomScrollView(
                                        controller: _scrollController,

                                        // The newest edge is scroll offset zero. A newly
                                        // created chat therefore paints already at the latest
                                        // message instead of calculating and jumping to the
                                        // end after layout.
                                        reverse: true,

                                        clipBehavior: Clip.none,

                                        // Scrolling through messages must NOT dismiss
                                        // the IME. Empty-space taps and text-message
                                        // taps explicitly own keyboard dismissal.
                                        keyboardDismissBehavior:
                                            ScrollViewKeyboardDismissBehavior
                                                .manual,

                                        slivers: [
                                          // In this reversed viewport the first sliver is the
                                          // physical bottom. Reserve exactly the composer's real
                                          // height plus 8dp so offset zero leaves the newest bubble
                                          // resting above the composer. Because the VIEWPORT itself
                                          // still extends behind the composer, scrolling moves older
                                          // bubbles through this reserved area and visibly behind the
                                          // glass composer instead of clipping them at its top edge.
                                          // Keep the exact same bottom geometry while selecting.
                                          // The composer remains mounted and the reversed viewport
                                          // must not re-anchor its messages when selection begins.
                                          SliverToBoxAdapter(
                                            child: SizedBox(
                                              height: composerOverlayExtent + 8,
                                            ),
                                          ),

                                          // Sections are stored oldest -> newest. Build them
                                          // newest -> oldest because the viewport itself is
                                          // reversed. The final visual order remains the normal
                                          // chronological oldest-at-top / newest-at-bottom order.
                                          for (
                                            var sectionIndex =
                                                timelineSections.length - 1;
                                            sectionIndex >= 0;
                                            sectionIndex--
                                          )
                                            SliverMainAxisGroup(
                                              key: ValueKey<String>(
                                                'chat-day-${timelineSections[sectionIndex].label}-$sectionIndex',
                                              ),
                                              slivers: [
                                                // In a reversed viewport the first child in the
                                                // group is closest to the physical bottom, so
                                                // messages are also emitted newest -> oldest.
                                                SliverPadding(
                                                  padding: EdgeInsets.symmetric(
                                                    horizontal: metrics
                                                        .horizontalPadding,
                                                  ),
                                                  sliver: SliverList.builder(
                                                    itemCount:
                                                        timelineSections[sectionIndex]
                                                            .entries
                                                            .length,
                                                    itemBuilder: (context, localIndex) {
                                                      final entries =
                                                          timelineSections[sectionIndex]
                                                              .entries;
                                                      final entry =
                                                          entries[entries
                                                                  .length -
                                                              1 -
                                                              localIndex];
                                                      final message =
                                                          entry.message;
                                                      final index =
                                                          entry.messageIndex;

                                                      return Padding(
                                                        padding: EdgeInsets.only(
                                                          bottom:
                                                              _messageGapAfter(
                                                                model.messages,
                                                                index,
                                                                model
                                                                    .config
                                                                    .kind,
                                                              ),
                                                        ),
                                                        child: ChatMessageSelectionRow(
                                                          key:
                                                              _messageRowKeyFor(
                                                                message.id,
                                                              ),
                                                          message: message,
                                                          selectionMode:
                                                              selectionMode,
                                                          selected:
                                                              _selectionModel
                                                                  .isSelected(
                                                                    message.id,
                                                                  ),
                                                          highlightPulse:
                                                              _pinnedHighlightMessageId ==
                                                                  message.id
                                                              ? _pinnedHighlightPulse
                                                              : 0,
                                                          onToggle: () {
                                                            _toggleMessageSelection(
                                                              message,
                                                            );
                                                          },
                                                          child: ChatMessageBubble(
                                                            message: message,
                                                            onTextTap:
                                                                _handleConversationTap,
                                                            isPinned:
                                                                _pinnedMessageIds
                                                                    .contains(
                                                                      message
                                                                          .id,
                                                                    ),
                                                            showTail:
                                                                _showsTail(
                                                                  model
                                                                      .messages,
                                                                  index,
                                                                  model
                                                                      .config
                                                                      .kind,
                                                                ),
                                                            audioPlayback:
                                                                audioPlayback,
                                                            videoPlayback:
                                                                _videoPlayback,
                                                            usePinChoices:
                                                                model
                                                                    .config
                                                                    .kind ==
                                                                ChatConversationKind
                                                                    .direct,
                                                            onBeforeVideoPlay:
                                                                audioPlayback
                                                                    .stopAndClear,
                                                            onActionSelected:
                                                                _handleMessageAction,
                                                            onReactionSelected:
                                                                (
                                                                  message,
                                                                  reaction,
                                                                ) {
                                                                  _showChatNotice(
                                                                    'Reacted $reaction',
                                                                  );
                                                                },
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),

                                                // The encryption notice visually belongs
                                                // between the oldest date chip and its first
                                                // message. Because this viewport is reversed it
                                                // comes after the messages in sliver order.
                                                if (sectionIndex == 0)
                                                  const SliverPadding(
                                                    padding: EdgeInsets.only(
                                                      top: 7,
                                                      bottom: 34,
                                                    ),
                                                    sliver: SliverToBoxAdapter(
                                                      child: Center(
                                                        child:
                                                            ChatEncryptionNotice(),
                                                      ),
                                                    ),
                                                  ),

                                                // Date chip comes last in each reversed group so
                                                // it paints above that section's messages.
                                                SliverToBoxAdapter(
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          vertical: 11.5,
                                                        ),
                                                    child: Center(
                                                      child:
                                                          ValueListenableBuilder<
                                                            _FloatingDateOverlayState
                                                          >(
                                                            valueListenable:
                                                                _floatingDateOverlay,
                                                            builder:
                                                                (
                                                                  context,
                                                                  floatingDate,
                                                                  child,
                                                                ) {
                                                                  final ownedByOverlay =
                                                                      floatingDate
                                                                          .ownsInlineDate &&
                                                                      floatingDate
                                                                              .sectionIndex ==
                                                                          sectionIndex;

                                                                  return IgnorePointer(
                                                                    ignoring:
                                                                        ownedByOverlay,
                                                                    child: Opacity(
                                                                      opacity:
                                                                          ownedByOverlay
                                                                          ? 0
                                                                          : 1,
                                                                      child:
                                                                          child,
                                                                    ),
                                                                  );
                                                                },
                                                            child: _ChatDateChip(
                                                              key: _dateChipKeyFor(
                                                                sectionIndex,
                                                              ),
                                                              label:
                                                                  timelineSections[sectionIndex]
                                                                      .label,
                                                            ),
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),

                                          // These were the leading spacers in the old normal
                                          // viewport. They come LAST in a reversed viewport so
                                          // they still occupy the physical top under the header.
                                          const SliverToBoxAdapter(
                                            child: SizedBox(height: 7),
                                          ),

                                          SliverToBoxAdapter(
                                            child: AnimatedContainer(
                                              duration:
                                                  MediaQuery.disableAnimationsOf(
                                                    context,
                                                  )
                                                  ? Duration.zero
                                                  : const Duration(
                                                      milliseconds: 240,
                                                    ),
                                              curve: Curves.easeOutCubic,
                                              height:
                                                  headerExtent +
                                                  (showPinnedStrip
                                                      ? ChatPinnedStrip.extent
                                                      : 0.0),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            AnimatedPositionedDirectional(
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 240),
                              curve: Curves.easeOutCubic,
                              top: _dateStickyTop,
                              start: 0,
                              end: 0,
                              child: IgnorePointer(
                                child:
                                    ValueListenableBuilder<
                                      _FloatingDateOverlayState
                                    >(
                                      valueListenable: _floatingDateOverlay,
                                      builder: (context, floatingDate, _) {
                                        if (!floatingDate.hasDate ||
                                            !floatingDate.ownsInlineDate) {
                                          return const SizedBox.shrink();
                                        }

                                        return ValueListenableBuilder<bool>(
                                          valueListenable: _dateHeaderVisible,
                                          builder: (context, visible, _) {
                                            return AnimatedOpacity(
                                              opacity: visible ? 1 : 0,
                                              duration: visible
                                                  ? const Duration(
                                                      milliseconds: 110,
                                                    )
                                                  : const Duration(
                                                      milliseconds: 150,
                                                    ),
                                              curve: visible
                                                  ? Curves.easeOutCubic
                                                  : Curves.easeInCubic,
                                              child: Transform.translate(
                                                offset: Offset(
                                                  0,
                                                  floatingDate.outgoingOffsetY,
                                                ),
                                                child: Center(
                                                  child: _ChatDateChip(
                                                    label: floatingDate.label!,
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    ),
                              ),
                            ),

                            // The pinned strip grows outward from the center of
                            // the header, while the matching sliver spacer and
                            // floating date position animate by the same extent.
                            PositionedDirectional(
                              top: headerExtent,
                              start: 0,
                              end: 0,
                              child: AnimatedSwitcher(
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 250),
                                reverseDuration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 210),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                layoutBuilder:
                                    (currentChild, previousChildren) {
                                      return Stack(
                                        alignment: Alignment.topCenter,
                                        children: [
                                          ...previousChildren,
                                          if (currentChild != null)
                                            currentChild,
                                        ],
                                      );
                                    },
                                transitionBuilder: (child, animation) {
                                  final curved = CurvedAnimation(
                                    parent: animation,
                                    curve: Curves.easeOutCubic,
                                    reverseCurve: Curves.easeInCubic,
                                  );

                                  return FadeTransition(
                                    opacity: curved,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0, -.12),
                                        end: Offset.zero,
                                      ).animate(curved),
                                      child: AnimatedBuilder(
                                        animation: curved,
                                        child: child,
                                        builder: (context, child) {
                                          final t = curved.value;
                                          final widthFactor = .28 + (.72 * t);

                                          return ClipRect(
                                            child: Center(
                                              child: FractionallySizedBox(
                                                widthFactor: widthFactor,
                                                child: Transform.scale(
                                                  scale: .96 + (.04 * t),
                                                  alignment:
                                                      Alignment.topCenter,
                                                  child: child,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  );
                                },
                                child: showPinnedStrip
                                    ? ChatPinnedStrip(
                                        key: const ValueKey<String>(
                                          'pinned-strip-visible',
                                        ),
                                        messages: pinnedMessages,

                                        // Body tap:
                                        // navigate inside this conversation and
                                        // pulse the selected pinned row.
                                        onMessageSelected: (message) {
                                          unawaited(
                                            _revealPinnedMessage(
                                              message,
                                              model,
                                            ),
                                          );
                                        },

                                        // Only the explicit menu icon for
                                        // multiple pins opens the full pin list.
                                        onOpenList: () {
                                          unawaited(
                                            _openPinnedMessages(
                                              model,
                                              audioPlayback,
                                            ),
                                          );
                                        },

                                        onDismiss: () {
                                          setState(
                                            () =>
                                                _dismissedPinnedStripSignature =
                                                    pinnedSignature,
                                          );
                                        },
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey<String>(
                                          'pinned-strip-hidden',
                                        ),
                                      ),
                              ),
                            ),

                            PositionedDirectional(
                              top: 0,

                              start: 0,

                              end: 0,

                              child: ChatHeaderBackdrop(
                                pillBottom: headerPillBottom,

                                overlayHeight: headerOverlayHeight,

                                child: AnimatedSwitcher(
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 180),

                                  switchInCurve: Curves.easeOutCubic,

                                  switchOutCurve: Curves.easeInCubic,

                                  child: selectionMode
                                      ? ChatSelectionHeader(
                                          key: const ValueKey<String>(
                                            'chat-selection-header',
                                          ),

                                          selectedCount:
                                              _selectionModel.selectedCount,

                                          onClose: _selectionModel.clear,

                                          onPin: () {
                                            setState(() {
                                              if (_selectionActionMenu ==
                                                  _SelectionActionMenu.pin) {
                                                _selectionActionMenu =
                                                    _SelectionActionMenu.none;
                                              } else {
                                                _selectionActionMenuContent =
                                                    _SelectionActionMenu.pin;
                                                _selectionActionMenu =
                                                    _SelectionActionMenu.pin;
                                              }
                                            });
                                          },

                                          onCopy: () => unawaited(
                                            _copySelectedMessages(model),
                                          ),

                                          onForward: () => unawaited(
                                            _forwardSelectedMessages(
                                              selectedMessages,
                                            ),
                                          ),

                                          onDelete: () {
                                            setState(() {
                                              if (_selectionActionMenu ==
                                                  _SelectionActionMenu.delete) {
                                                _selectionActionMenu =
                                                    _SelectionActionMenu.none;
                                              } else {
                                                _selectionActionMenuContent =
                                                    _SelectionActionMenu.delete;
                                                _selectionActionMenu =
                                                    _SelectionActionMenu.delete;
                                              }
                                            });
                                          },
                                        )
                                      : ChatHeader(
                                          key: const ValueKey<String>(
                                            'chat-normal-header',
                                          ),

                                          config: model.config,

                                          onBack: _handleBack,

                                          onCallPressed: _toggleCallMenu,

                                          onProfilePressed: () => context.push(
                                            AppRoutes.profile,
                                            extra: ProfileScreenData(
                                              name: model.config.title,
                                              identifier: '+250 791 568 677',
                                              avatarAsset:
                                                  model.config.avatarAsset,
                                              isOwnProfile: false,
                                              bio:
                                                  'Private calls, messaging, and communication.',
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            ),

                            // Selection Pin/Delete use the exact message-action
                            // menu surface, aligned beneath the selection pill.
                            // Its top-right expansion mirrors the full-screen
                            // photo delete confirmation motion.
                            if (selectionMode)
                              PositionedDirectional(
                                top: headerExtent + 4,
                                end: selectionMenuEnd,
                                child: TweenAnimationBuilder<double>(
                                  key: const ValueKey<String>(
                                    'chat-selection-action-menu-animation',
                                  ),
                                  tween: Tween<double>(
                                    end:
                                        _selectionActionMenu !=
                                            _SelectionActionMenu.none
                                        ? 1
                                        : 0,
                                  ),
                                  duration: const Duration(milliseconds: 190),
                                  curve:
                                      _selectionActionMenu !=
                                          _SelectionActionMenu.none
                                      ? Curves.easeOutCubic
                                      : Curves.easeInCubic,
                                  builder: (context, progress, child) {
                                    return IgnorePointer(
                                      ignoring: progress < .98,
                                      child: Opacity(
                                        opacity: progress,
                                        child: Transform.scale(
                                          scale: progress,
                                          alignment: Alignment.topRight,
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                  child: SizedBox(
                                    width: selectionMenuWidth,
                                    height: selectionMenuHeight,
                                    child: MessageActionMenu(
                                      actions: selectionMenuActions,
                                      maxHeight: selectionMenuHeight,
                                      onSelected: (action) {
                                        final future =
                                            switch (_selectionActionMenu) {
                                              _SelectionActionMenu.pin =>
                                                _handleSelectionPinAction(
                                                  model,
                                                  action,
                                                ),
                                              _SelectionActionMenu.delete =>
                                                _handleSelectionDeleteAction(
                                                  model,
                                                  action,
                                                ),
                                              _SelectionActionMenu.none =>
                                                Future<void>.value(),
                                            };

                                        unawaited(future);
                                      },
                                    ),
                                  ),
                                ),
                              ),

                            // ===============================================================
                            // Scroll to latest
                            // ===============================================================
                            //
                            // The viewport now continues behind the composer, so anchor this
                            // control to the measured composer TOP instead of the viewport bottom.
                            // Keeping the old -4 relationship preserves the visual spacing.
                            PositionedDirectional(
                              end: metrics.horizontalPadding,
                              // Stable old-Wrytte geometry: safe bottom gap,
                              // composer top padding, recorder size, then the
                              // fixed breathing gap. Measured composer or IME
                              // height can no longer make this control jump.
                              bottom: scrollToLatestControlBottom,
                              child: _buildScrollToLatestControl(
                                metrics,
                                available:
                                    !selectionMode &&
                                    !_recordHintVisible &&
                                    !_recordingActive,
                              ),
                            ),

                            // ===============================================================

                            // Record mode hint

                            // ===============================================================
                            PositionedDirectional(
                              bottom: composerOverlayExtent - 4,

                              start: 12,

                              end: 12,

                              child: IgnorePointer(
                                ignoring: !_recordHintVisible || selectionMode,

                                child: Align(
                                  alignment: AlignmentDirectional.bottomEnd,

                                  child: WrytteAnimatedPopover(
                                    visible:
                                        _recordHintVisible && !selectionMode,

                                    alignment: Alignment.bottomRight,

                                    hiddenOffset: const Offset(0, .14),

                                    child: _RecordModeHint(
                                      mode: model.recordMode,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // ===============================================================

                            // Call options

                            // ===============================================================
                            PositionedDirectional(
                              top: popoverTop,

                              end: metrics.horizontalPadding,

                              child: WrytteAnimatedPopover(
                                visible: _callMenuVisible && !selectionMode,

                                alignment: Alignment.topRight,

                                hiddenOffset: const Offset(.08, -.12),

                                child: _CallOptions(
                                  callsAvailable: model.config.callsAvailable,

                                  onSelected: _hideTransientSurfaces,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Paint the composer above the full-height conversation. Its
                      // real height is measured (1 line, 5 lines, reply, edit, media,
                      // recording, SafeArea) and fed back into the reversed scroll spacer.
                      // This gives us both properties we want:
                      //   1) newest content rests above the composer at offset zero;
                      //   2) scrolled content can continue visibly behind the composer.
                      PositionedDirectional(
                        start: 0,
                        end: 0,
                        bottom: 0,
                        child: _MeasureSize(
                          onChange: _handleComposerSize,
                          child: ChatComposer(
                            controller: _messageController,

                            focusNode: _messageFocusNode,

                            recordMode: model.recordMode,

                            onSend: _send,

                            onToggleRecordMode: _toggleRecordMode,

                            replySender: _replyingTo == null
                                ? null
                                : _replyingTo!.isMine
                                ? 'You'
                                : (_replyingTo!.senderName?.trim().isNotEmpty ==
                                          true
                                      ? _replyingTo!.senderName!.trim()
                                      : 'Wrytte Team'),

                            replyPreview: _replyingTo == null
                                ? null
                                : _messagePreview(_replyingTo!),

                            onCancelReply: _replyingTo == null
                                ? null
                                : () => setState(() => _replyingTo = null),

                            isEditing: _editingMessage != null,

                            editingMediaSource: _editingMediaPath,

                            editingMediaType:
                                _editingMessage?.kind == ChatMessageKind.video
                                ? 'video'
                                : _editingMessage?.kind == ChatMessageKind.image
                                ? 'image'
                                : null,

                            onCancelEdit: _editingMessage == null
                                ? null
                                : _clearEditingState,

                            onReplaceEditingMedia:
                                _editingMessage?.kind ==
                                        ChatMessageKind.image ||
                                    _editingMessage?.kind ==
                                        ChatMessageKind.video
                                ? _openAttachments
                                : null,

                            onAttachmentPressed: _openAttachments,

                            onExpressPressed: () {},

                            onVoiceRecorded: (recording) {
                              model.sendPreviewVoice(
                                recording.path,
                                durationSeconds: recording
                                    .trimRange
                                    .duration
                                    .inSeconds
                                    .clamp(1, 3600),
                              );
                            },

                            onRoundVideoRecorded: (recording) {
                              model.sendPreviewRoundVideo(
                                recording.path,
                                durationSeconds:
                                    (recording.duration ??
                                            const Duration(seconds: 1))
                                        .inSeconds
                                        .clamp(1, 60),
                              );
                            },

                            onRecordingFailure: _showChatNotice,

                            onRecordingActiveChanged:
                                _handleRecordingActiveChanged,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================

  // Message grouping

  // ===========================================================================

  double _messageGapAfter(
    List<ChatMessagePresentation> messages,
    int index,
    ChatConversationKind conversationKind,
  ) {
    if (index >= messages.length - 1) {
      return 0;
    }

    if (messages[index].dayLabel != messages[index + 1].dayLabel) {
      return 0;
    }

    return _sameMessageAuthor(
          messages[index],
          messages[index + 1],
          conversationKind,
        )
        ? 2
        : 7;
  }

  bool _showsTail(
    List<ChatMessagePresentation> messages,
    int index,
    ChatConversationKind conversationKind,
  ) {
    if (index >= messages.length - 1) {
      return true;
    }

    final current = messages[index];
    final next = messages[index + 1];

    return next.dayLabel != current.dayLabel ||
        !_sameMessageAuthor(current, next, conversationKind);
  }

  bool _sameMessageAuthor(
    ChatMessagePresentation first,
    ChatMessagePresentation second,
    ChatConversationKind conversationKind,
  ) {
    if (first.isMine != second.isMine) {
      return false;
    }

    // Every outgoing message belongs to the current user. A direct chat also
    // has only one possible incoming participant.
    if (first.isMine || conversationKind == ChatConversationKind.direct) {
      return true;
    }

    // In groups and communities, two incoming messages only join when their
    // explicit sender identity matches. Missing identities stay separate so a
    // message from another participant never loses its tail by accident.
    final firstSender = first.senderName?.trim();
    final secondSender = second.senderName?.trim();

    return firstSender != null &&
        firstSender.isNotEmpty &&
        firstSender == secondSender;
  }
}

// =============================================================================
// Composer size measurement
// =============================================================================

/// Reports the composer's real laid-out size after layout.
///
/// This avoids hard-coding a composer height: multiline text, reply/edit
/// previews, recording UI, and system SafeArea can all change it. The callback
/// runs after the frame so it never calls setState during layout.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _MeasureSizeRenderObject(onChange);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _MeasureSizeRenderObject renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this.onChange);

  ValueChanged<Size> onChange;
  Size? _previousSize;

  @override
  void performLayout() {
    super.performLayout();

    final nextSize = size;
    if (_previousSize == nextSize) return;
    _previousSize = nextSize;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      onChange(nextSize);
    });
  }
}

// =============================================================================
// Independent keyboard movement boundary
// =============================================================================

/// Moves the conversation and composer from one shared explicit offset.
/// Opening is coordinated by ChatView (250ms total); closing is 200ms. The
/// boundary itself never guesses keyboard geometry and never starts a second
/// implicit animation when the destination changes.
class _KeyboardMotionBoundary extends StatelessWidget {
  const _KeyboardMotionBoundary({required this.offset, required this.child});

  final Animation<double> offset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: offset,
      child: child,
      builder: (context, child) {
        return Padding(
          padding: EdgeInsets.only(bottom: math.max(0.0, offset.value)),
          child: child,
        );
      },
    );
  }
}

// =============================================================================
// Sticky date section header
// =============================================================================

class _FloatingDateOverlayState {
  const _FloatingDateOverlayState({
    this.sectionIndex,
    this.label,
    this.outgoingOffsetY = 0,
    this.ownsInlineDate = false,
  });

  final int? sectionIndex;
  final String? label;
  final double outgoingOffsetY;
  final bool ownsInlineDate;

  bool get hasDate => sectionIndex != null && label != null;
}

class _MeasuredDateChip {
  const _MeasuredDateChip({
    required this.sectionIndex,
    required this.top,
    required this.bottom,
  });

  final int sectionIndex;
  final double top;
  final double bottom;
}

class _ChatDateChip extends StatelessWidget {
  const _ChatDateChip({super.key, required this.label});

  final String label;

  static const double _height = 23;
  static const double _horizontalPadding = 12;
  static const double _radius = 11.5;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: _height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              height: _height,
              padding: const EdgeInsets.symmetric(
                horizontal: _horizontalPadding,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1C222C).withValues(alpha: 0.70),
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.055),
                  width: 0.7,
                ),
              ),
              child: Align(
                alignment: Alignment.center,
                widthFactor: 1,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.58),
                    fontSize: 10.75,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================

// Wallpaper

// =============================================================================

class _ChatBackdrop extends StatelessWidget {
  const _ChatBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: WrytteColors.background,

        image: DecorationImage(
          image: const AssetImage('assets/images/chat_wallpaper.jpg'),

          fit: BoxFit.cover,

          colorFilter: ColorFilter.mode(
            WrytteColors.background.withValues(alpha: .84),

            BlendMode.srcOver,
          ),
        ),
      ),
    );
  }
}

// =============================================================================

// Record hint

// =============================================================================

class _RecordModeHint extends StatelessWidget {
  const _RecordModeHint({required this.mode});

  final ChatRecordMode mode;

  @override
  Widget build(BuildContext context) {
    final message = mode == ChatRecordMode.video
        ? 'Hold to record video  •  Tap to switch to audio'
        : 'Hold to record audio  •  Tap to switch to video';

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 24,
      ),

      child: WrytteGlassSurface(
        borderRadius: BorderRadius.circular(20),

        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),

        child: Text(
          message,

          softWrap: true,

          textAlign: TextAlign.center,

          style: const TextStyle(
            color: WrytteColors.textMuted,

            fontSize: 11,

            height: 1.15,
          ),
        ),
      ),
    );
  }
}

// =============================================================================

// Call menu

// =============================================================================

class _CallOptions extends StatelessWidget {
  const _CallOptions({required this.callsAvailable, required this.onSelected});

  final bool callsAvailable;

  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final options = callsAvailable
        ? const [
            (Icons.call_rounded, 'Voice call'),

            (Icons.videocam_rounded, 'Video call'),
          ]
        : const [
            (Icons.info_outline_rounded, 'Conversation info'),

            (Icons.notifications_none_rounded, 'Notifications'),
          ];

    return SizedBox(
      width: 182,

      child: WrytteGlassSurface(
        borderRadius: BorderRadius.circular(22),

        padding: const EdgeInsets.symmetric(vertical: 5),

        child: Column(
          mainAxisSize: MainAxisSize.min,

          children: [
            for (final option in options)
              Semantics(
                button: true,

                label: option.$2,

                child: InkWell(
                  onTap: onSelected,

                  child: SizedBox(
                    height: 46,

                    child: Row(
                      children: [
                        const SizedBox(width: 15),

                        Icon(
                          option.$1,

                          size: 21,

                          color: WrytteColors.textPrimary,
                        ),

                        const SizedBox(width: 12),

                        Text(
                          option.$2,

                          style: const TextStyle(
                            color: WrytteColors.textPrimary,

                            fontSize: 14,

                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
