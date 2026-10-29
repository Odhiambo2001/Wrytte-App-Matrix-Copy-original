import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/ui/chat/models/chat_screen_config.dart';
import 'package:wrytte/ui/chat/widgets/chat_layout_metrics.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_icon_button.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.config,
    required this.onBack,
    required this.onCallPressed,
    this.onProfilePressed,
    this.avatarUrl,
    this.localAvatarPath,
    this.avatarCacheIdentity,
    this.isDeleted = false,
    this.hasAutoDelete = false,
    this.suppressAvatar = false,
  });

  final ChatScreenConfig config;
  final VoidCallback onBack;
  final VoidCallback onCallPressed;
  final VoidCallback? onProfilePressed;
  final String? avatarUrl;
  final String? localAvatarPath;
  final String? avatarCacheIdentity;
  final bool isDeleted;
  final bool hasAutoDelete;
  final bool suppressAvatar;

  @override
  Widget build(BuildContext context) {
    final metrics = ChatLayoutMetrics.of(context);
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: metrics.headerHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.horizontalPadding),
          child: Row(
            children: [
              WrytteGlassIconButton(
                semanticLabel: 'Back',
                onPressed: onBack,
                size: metrics.controlSize,
                child: WrytteSvgIcon(
                  asset: 'assets/svg/ic--round-arrow-back-ios.svg',
                  size: 26 * metrics.scale,
                  color: WrytteColors.textPrimary,
                ),
              ),
              SizedBox(width: metrics.controlGap),
              Expanded(
                child: Semantics(
                  button: onProfilePressed != null,
                  label: 'Open ${config.title} details',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onProfilePressed,
                    child: SizedBox(
                      height: metrics.controlSize,
                      child: WrytteGlassSurface(
                        borderRadius: BorderRadius.circular(
                          metrics.controlSize / 2,
                        ),
                        child: Row(
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                UserAvatar(
                                  size: metrics.controlSize,
                                  imageUrl: avatarUrl,
                                  localImagePath: localAvatarPath,
                                  cacheIdentity: avatarCacheIdentity,
                                  name: config.title,
                                  isDeleted: isDeleted,
                                  suppressAvatar: suppressAvatar,
                                ),
                                if (hasAutoDelete)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: SizedBox(
                                      width: metrics.controlSize * 0.4,
                                      height: metrics.controlSize * 0.4,
                                      child: SvgPicture.asset(
                                        'assets/images/Disappearing messages icon.svg',
                                        colorFilter: const ColorFilter.mode(
                                          Colors.white,
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            SizedBox(width: 10 * metrics.scale),
                            Expanded(
                              child: MediaQuery.withClampedTextScaling(
                                maxScaleFactor: 1.3,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      config.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: WrytteColors.textPrimary,
                                        fontSize: 17 * metrics.scale,
                                        height: 1,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 3 * metrics.scale),
                                    Text(
                                      config.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: WrytteColors.textMuted,
                                        fontSize: 13 * metrics.scale,
                                        height: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(width: 8 * metrics.scale),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: metrics.controlGap),
              WrytteGlassIconButton(
                semanticLabel: config.callsAvailable
                    ? 'Call options'
                    : 'Conversation options',
                onPressed: onCallPressed,
                size: metrics.controlSize,
                child: config.callsAvailable
                    ? _ComposedCallIcon(scale: metrics.scale)
                    : Icon(
                        Icons.more_vert_rounded,
                        size: 22 * metrics.scale,
                        color: WrytteColors.textPrimary,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposedCallIcon extends StatelessWidget {
  const _ComposedCallIcon({required this.scale});

  final double scale;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(-.75 * scale, 2 * scale),
      child: SizedBox(
        width: 30 * scale,
        height: 29 * scale,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 1 * scale,
              child: WrytteSvgIcon(
                asset: 'assets/svg/solar--phone-linear.svg',
                size: 26 * scale,
                color: WrytteColors.textPrimary,
              ),
            ),
            Positioned(
  left: 19 * scale,
  top: 4 * scale,
  child: WrytteSvgIcon(
    asset: 'assets/svg/Chevron down icon.svg',
    size: 12 * scale,
    color: WrytteColors.textPrimary,
  ),
),
          ],
        ),
      ),
    );
  }
}
