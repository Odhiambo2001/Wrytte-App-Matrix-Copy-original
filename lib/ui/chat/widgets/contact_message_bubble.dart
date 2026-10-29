import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wrytte/services/user/user_profile_service.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';

import 'package:wrytte/ui/chat/widgets/message_actions/message_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';

import 'package:wrytte/ui/chat/widgets/message_bubble_surface.dart';

import 'package:wrytte/ui/chat/widgets/message_metadata.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class ContactMessageBubble extends StatelessWidget {

  const ContactMessageBubble({

    super.key,

    required this.message,

    this.showTail = true,

    this.actionConfig,

    this.onMessage,

    this.onSecondaryAction,

  });

  // ===========================================================================

  // Geometry

  // ===========================================================================

  static const double _responsiveWidthFactor = 0.65;

  static const double _minimumContentWidth = 210;

  static const double _maximumContentWidth = 250;

  static const double _bubbleRadius = 20;

  static const double _horizontalPadding = 12;

  static const double _verticalPadding = 8;

  static const double _avatarSize = 44;

  static const double _avatarTextGap = 10;

  static const double _namePhoneGap = 5;

  static const double _phoneTimeGap = 3;

  // MessageMetadata uses up to 17 logical pixels for sent/delivered/read

  // status icons. Keep the Contact metadata row at that intrinsic height so

  // those icons are never visually squeezed by this bubble.

  static const double _timeRowHeight = 17;

  static const double _headerDividerGap = 12;

  static const double _dividerThickness = 1;

  static const double _actionRowHeight = 46;

  static const double _surfaceVerticalMargin = 1;

  // Same effective trailing position as TextMessageBubble.

  //

  // Text bubble:

  // 12px content padding

  // outgoing metadata moves +5px

  //

  // 12 - 5 = 7px

  static const double _incomingMetadataEndInset = 12;

  static const double _outgoingMetadataEndInset = 7;

  // ===========================================================================

  // Data

  // ===========================================================================

  final ChatMessagePresentation message;

  final bool showTail;

  final MessageActionConfig? actionConfig;

  final Future<void> Function()? onMessage;

  final Future<void> Function()? onSecondaryAction;

  // ===========================================================================

  // Build

  // ===========================================================================

  @override

  Widget build(BuildContext context) {
    final userId = message.contactUserId?.trim() ?? '';
    if (userId.isEmpty || message.contactAvatarUrl?.trim().isNotEmpty == true) {
      return _buildBubble(context, message);
    }

    return FutureBuilder<UserProfile?>(
      future: UserProfileService.instance.getProfileByUid(userId),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final avatar = profile?.profileImage.trim();
        if (avatar == null || avatar.isEmpty) {
          return _buildBubble(context, message);
        }
        return _buildBubble(
          context,
          message.copyWith(contactAvatarUrl: avatar),
        );
      },
    );
  }

  Widget _buildBubble(
    BuildContext context,
    ChatMessagePresentation message,
  ) {

    final name = _cleanName(

      message.contactName,

    );

    final phone = _cleanPhone(

      message.contactPhone,

    );

    final bubbleColor = message.isMine

        ? WrytteColors.primary

        : WrytteColors.surfaceRaised;

    return LayoutBuilder(

      builder: (context, constraints) {

        final viewportWidth =

            MediaQuery.sizeOf(context).width;

        final preferredContentWidth =

            (viewportWidth * _responsiveWidthFactor)

                .clamp(

                  _minimumContentWidth,

                  _maximumContentWidth,

                )

                .toDouble();

        final availableWidth =

            constraints.hasBoundedWidth

            ? constraints.maxWidth

            : viewportWidth;

        final tailExtent = showTail

            ? MessageBubbleSurface.tailExtent

            : 0.0;

        final maximumContentWidth =

            (availableWidth -

                    tailExtent -

                    (_horizontalPadding * 2))

                .clamp(

                  0.0,

                  double.infinity,

                )

                .toDouble();

        final contentWidth =

            preferredContentWidth

                .clamp(

                  0.0,

                  maximumContentWidth,

                )

                .toDouble();

        final surfaceWidth =

            contentWidth +

            (_horizontalPadding * 2) +

            tailExtent;

        final bubble = SizedBox(

          width: surfaceWidth,

          child: MessageBubbleSurface(

            isMine: message.isMine,

            showTail: showTail,

            color: bubbleColor,

            radius: _bubbleRadius,

            child: SizedBox(

              width:

                  contentWidth +

                  (_horizontalPadding * 2),

              child: _ContactBubbleContent(

                message: message,

                name: name,

                phone: phone,

                onMessage: onMessage,

                onSecondaryAction:

                    onSecondaryAction,

              ),

            ),

          ),

        );

        final bubbleWithMargin =

            Padding(

          padding:

              const EdgeInsets.symmetric(

            vertical:

                _surfaceVerticalMargin,

          ),

          child: bubble,

        );

        final groupedInset = showTail

            ? EdgeInsets.zero

            : EdgeInsetsDirectional.only(

                start: message.isMine

                    ? 0

                    : MessageBubbleSurface

                        .tailExtent,

                end: message.isMine

                    ? MessageBubbleSurface

                        .tailExtent

                    : 0,

              );

        final content = Padding(

          padding: groupedInset,

          child: bubbleWithMargin,

        );

        final config = actionConfig;

        return Align(

          alignment: message.isMine

              ? AlignmentDirectional.centerEnd

              : AlignmentDirectional.centerStart,

          child:

              config == null ||

                  !config.hasContent

              ? content

              : MessageActionTarget(
                  config: config,
                  child: MessageSwipeActionTarget(
                    config: config,
                    child: content,
                  ),
                ),

        );

      },

    );

  }

  // ===========================================================================

  // Normalization

  // ===========================================================================

  static String _cleanName(

    String? value,

  ) {

    final clean =

        value?.trim() ?? '';

    return clean.isEmpty

        ? 'Contact'

        : clean;

  }

  static String _cleanPhone(

    String? value,

  ) {

    final clean =

        value?.trim() ?? '';

    return clean.isEmpty

        ? 'Contact'

        : clean;

  }

}

// =============================================================================

// Contact bubble content

// =============================================================================

class _ContactBubbleContent

    extends StatelessWidget {

  const _ContactBubbleContent({

    required this.message,

    required this.name,

    required this.phone,

    required this.onMessage,

    required this.onSecondaryAction,

  });

  final ChatMessagePresentation message;

  final String name;

  final String phone;

  final Future<void> Function()?

  onMessage;

  final Future<void> Function()?

  onSecondaryAction;

  @override

  Widget build(BuildContext context) {

    final actionColor =

        message.isMine

        ? Colors.white

        : WrytteColors.primary;

    final dividerColor =

        Colors.white.withValues(

      alpha: message.isMine

          ? 0.26

          : 0.12,

    );

    final metadataEndInset =

        message.isMine

        ? ContactMessageBubble

            ._outgoingMetadataEndInset

        : ContactMessageBubble

            ._incomingMetadataEndInset;

    return Column(

      mainAxisSize: MainAxisSize.min,

      crossAxisAlignment:

          CrossAxisAlignment.stretch,

      children: [

        // =============================================================

        // Top bubble spacing

        // =============================================================

        const SizedBox(

          height:

              ContactMessageBubble

                  ._verticalPadding,

        ),

        // =============================================================

        // Avatar + contact information

        //

        // Old contact content keeps its 12px horizontal padding.

        // =============================================================

        Padding(

          padding:

              const EdgeInsets.symmetric(

            horizontal:

                ContactMessageBubble

                    ._horizontalPadding,

          ),

          child: _ContactHeader(

            message: message,

            name: name,

            phone: phone,

          ),

        ),

        // =============================================================

        // Phone -> timestamp gap

        // =============================================================

        const SizedBox(

          height:

              ContactMessageBubble

                  ._phoneTimeGap,

        ),

        // =============================================================

        // Message metadata

        //

        // IMPORTANT:

        // - This does NOT use the contact content's 12px Padding.

        // - Padding still applies normally to the header/divider/actions.

        // - Timestamp and status icons keep MessageMetadata's intrinsic size.

        // - The end inset changes position only; it never scales the child.

        // =============================================================

        SizedBox(

          height: ContactMessageBubble._timeRowHeight,

          child: Stack(

            clipBehavior: Clip.none,

            children: [

              PositionedDirectional(

                end: metadataEndInset,

                bottom: 0,

                child: RepaintBoundary(

                  child: MessageMetadata(

                    message: message,

                  ),

                ),

              ),

            ],

          ),

        ),

        // =============================================================

        // Metadata -> divider gap

        // =============================================================

        const SizedBox(

          height:

              ContactMessageBubble

                  ._headerDividerGap,

        ),

        // =============================================================

        // Horizontal separator

        //

        // Same 12px inset as the old contact UI.

        // =============================================================

        Padding(

          padding:

              const EdgeInsets.symmetric(

            horizontal:

                ContactMessageBubble

                    ._horizontalPadding,

          ),

          child: Divider(

            height:

                ContactMessageBubble

                    ._dividerThickness,

            thickness:

                ContactMessageBubble

                    ._dividerThickness,

            color: dividerColor,

          ),

        ),

        // =============================================================

        // Bottom actions

        //

        // No vertical separator between the two actions.

        // =============================================================

        Padding(

          padding:

              const EdgeInsets.symmetric(

            horizontal:

                ContactMessageBubble

                    ._horizontalPadding,

          ),

          child: _ContactActions(

            message: message,

            actionColor: actionColor,

            onMessage: onMessage,

            onSecondaryAction:

                onSecondaryAction,

          ),

        ),

        // =============================================================

        // Bottom bubble spacing

        // =============================================================

        const SizedBox(

          height:

              ContactMessageBubble

                  ._verticalPadding,

        ),

      ],

    );

  }

}

// =============================================================================

// Contact header

// =============================================================================

class _ContactHeader

    extends StatelessWidget {

  const _ContactHeader({

    required this.message,

    required this.name,

    required this.phone,

  });

  final ChatMessagePresentation message;

  final String name;

  final String phone;

  @override

  Widget build(BuildContext context) {

    return Row(

      crossAxisAlignment:

          CrossAxisAlignment.center,

      children: [

        _ContactAvatar(

          name: name,

          avatarUrl:

              message.contactAvatarUrl,

        ),

        const SizedBox(

          width:

              ContactMessageBubble

                  ._avatarTextGap,

        ),

        Expanded(

          child: Column(

            mainAxisSize:

                MainAxisSize.min,

            crossAxisAlignment:

                CrossAxisAlignment.start,

            children: [

              // -------------------------------------------------------

              // Contact name

              // -------------------------------------------------------

              Text(

                name,

                maxLines: 1,

                overflow:

                    TextOverflow.ellipsis,

                style:

                    const TextStyle(

                  fontFamily:

                      WrytteTypography

                          .primaryFontFamily,

                  color: Colors.white,

                  fontSize: 17,

                  fontWeight:

                      FontWeight.w600,

                  height: 1.12,

                ),

              ),

              // -------------------------------------------------------

              // Name -> phone gap

              // -------------------------------------------------------

              const SizedBox(

                height:

                    ContactMessageBubble

                        ._namePhoneGap,

              ),

              // -------------------------------------------------------

              // Phone number

              // -------------------------------------------------------

              Align(

                alignment:

                    AlignmentDirectional

                        .centerStart,

                child: FittedBox(

                  fit:

                      BoxFit.scaleDown,

                  alignment:

                      AlignmentDirectional

                          .centerStart,

                  child: Text(

                    phone,

                    maxLines: 1,

                    softWrap: false,

                    style:

                        const TextStyle(

                      fontFamily:

                          WrytteTypography

                              .primaryFontFamily,

                      color:

                          Color(

                            0xBFC6C6C6,

                          ),

                      fontSize: 15,

                      fontWeight:

                          FontWeight.w500,

                      height: 1,

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

}

// =============================================================================

// Contact avatar

// =============================================================================

class _ContactAvatar

    extends StatelessWidget {

  const _ContactAvatar({

    required this.name,

    required this.avatarUrl,

  });

  final String name;

  final String? avatarUrl;

  @override

  Widget build(BuildContext context) {

    final source =

        avatarUrl?.trim() ?? '';

    return Semantics(

      image: true,

      label:

          '$name contact photo',

      child: ClipOval(

        child: SizedBox.square(

          dimension:

              ContactMessageBubble

                  ._avatarSize,

          child:

              _buildAvatar(source),

        ),

      ),

    );

  }

  Widget _buildAvatar(

    String source,

  ) {

    if (source.isEmpty) {

      return _fallbackAvatar();

    }

    if (source.startsWith(

      'assets/',

    )) {

      return Image.asset(

        source,

        fit: BoxFit.cover,

        filterQuality:

            FilterQuality.medium,

        errorBuilder: (

          context,

          error,

          stackTrace,

        ) {

          return _fallbackAvatar();

        },

      );

    }

    return Image.network(

      source,

      fit: BoxFit.cover,

      gaplessPlayback: true,

      filterQuality:

          FilterQuality.medium,

      errorBuilder: (

        context,

        error,

        stackTrace,

      ) {

        return _fallbackAvatar();

      },

    );

  }

  Widget _fallbackAvatar() {

    return Image.asset(

      'assets/images/default_avatar.jpg',

      fit: BoxFit.cover,

      filterQuality:

          FilterQuality.medium,

    );

  }

}

// =============================================================================

// Bottom actions

// =============================================================================

class _ContactActions

    extends StatelessWidget {

  const _ContactActions({

    required this.message,

    required this.actionColor,

    required this.onMessage,

    required this.onSecondaryAction,

  });

  final ChatMessagePresentation message;

  final Color actionColor;

  final Future<void> Function()?

  onMessage;

  final Future<void> Function()?

  onSecondaryAction;

  @override

  Widget build(BuildContext context) {

    // A shared profile is already a resolvable Wrytte user. It should not be
    // treated as an address-book contact on either side of the conversation.
    final secondaryLabel = 'View profile';

    return SizedBox(

      height:

          ContactMessageBubble

              ._actionRowHeight,

      child: Row(

        children: [

          Expanded(

            child:

                _ContactActionButton(

              label: 'Message',

              color: actionColor,

              onPressed: onMessage,

            ),

          ),

          // Old contact bubble had no vertical divider here.

          Expanded(

            child:

                _ContactActionButton(

              label:

                  secondaryLabel,

              color: actionColor,

              onPressed:

                  onSecondaryAction,

            ),

          ),

        ],

      ),

    );

  }

}

// =============================================================================

// Contact action button

// =============================================================================

class _ContactActionButton

    extends StatelessWidget {

  const _ContactActionButton({

    required this.label,

    required this.color,

    required this.onPressed,

  });

  final String label;

  final Color color;

  final Future<void> Function()?

  onPressed;

  @override

  Widget build(BuildContext context) {

    return TextButton(

      onPressed: () {

        final callback =

            onPressed;

        if (callback != null) {

          unawaited(

            callback(),

          );

        }

      },

      style: TextButton.styleFrom(

        foregroundColor: color,

        padding: EdgeInsets.zero,

        minimumSize: Size.zero,

        tapTargetSize:

            MaterialTapTargetSize

                .shrinkWrap,

        shape:

            const RoundedRectangleBorder(),

      ),

      child: FittedBox(

        fit:

            BoxFit.scaleDown,

        child: Text(

          label,

          maxLines: 1,

          style:

              const TextStyle(

            fontFamily:

                WrytteTypography

                    .primaryFontFamily,

            fontSize: 15,

            fontWeight:

                FontWeight.w500,

          ),

        ),

      ),

    );

  }

}
