import 'dart:collection';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';

import 'package:wrytte/ui/chat/widgets/message_bubble_surface.dart';

import 'package:wrytte/ui/chat/widgets/message_actions/message_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';

import 'package:wrytte/ui/chat/widgets/message_metadata.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class TextMessageBubble extends StatelessWidget {

  const TextMessageBubble({

    super.key,

    required this.message,

    this.showTail = true,

    this.actionConfig,

  });

  static const double _horizontalPadding = 12;

  static const double _preferredMetadataGap = 8;

  static const double _minimumMetadataGap = 6;

  // Outgoing metadata is painted 5px farther toward the trailing edge.

  // The resolver must use the same geometry when deciding whether metadata

  // fits on the final text line.

  static const double _outgoingMetadataPaintShift = 5;

  static const double _absoluteMaxSurfaceWidth = 420;

  static const TextStyle _bodyStyle = TextStyle(

    fontFamily: WrytteTypography.primaryFontFamily,

    color: WrytteColors.textPrimary,

    fontSize: 16,

    fontWeight: FontWeight.w400,

    height: 1.28,

  );

  final ChatMessagePresentation message;

  final bool showTail;

  final MessageActionConfig? actionConfig;

  @override

  Widget build(BuildContext context) {

    return LayoutBuilder(

      builder: (context, constraints) {

        final viewportWidth = MediaQuery.sizeOf(context).width;

        final responsiveMaximum = viewportWidth * .80;

        final availableWidth = constraints.hasBoundedWidth

            ? constraints.maxWidth

            : responsiveMaximum;

        final maximumSurfaceWidth = math.min(

          availableWidth,

          math.min(responsiveMaximum, _absoluteMaxSurfaceWidth),

        );

        final maximumContentWidth = math.max(

          0.0,

          maximumSurfaceWidth -

              MessageBubbleSurface.tailExtent -

              (_horizontalPadding * 2),

        );

        final metadataMetrics = MessageMetadata.measure(context, message);

        final layout = _TextLayoutResolver.resolve(

          context: context,

          message: message,

          style: _bodyStyle,

          maximumWidth: maximumContentWidth,

          metadataWidth: metadataMetrics.width,

        );

        final supplementaryWidth = _supplementaryContentWidth(

          context,

          maximumWidth: maximumContentWidth,

        );

        final contentWidth = math

            .max(layout.width, supplementaryWidth)

            .clamp(0.0, maximumContentWidth)

            .toDouble();

        final surfaceWidth =

            contentWidth +

            (_horizontalPadding * 2) +

            (showTail ? MessageBubbleSurface.tailExtent : 0);

        final groupedInset = showTail

            ? EdgeInsets.zero

            : EdgeInsetsDirectional.only(

                start: message.isMine ? 0 : MessageBubbleSurface.tailExtent,

                end: message.isMine ? MessageBubbleSurface.tailExtent : 0,

              );

        final bubble = SizedBox(

          width: surfaceWidth,

          child: MessageBubbleSurface(

            isMine: message.isMine,

            showTail: showTail,

            color: message.isMine

                ? WrytteColors.primary

                : WrytteColors.surfaceRaised,

            child: Padding(

              padding: const EdgeInsets.fromLTRB(12, 7, 12, 6),

              child: Column(

                mainAxisSize: MainAxisSize.min,

                crossAxisAlignment: CrossAxisAlignment.stretch,

                children: [

                  if (message.senderName case final sender?) ...[

                    Text(

                      sender,

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis,

                      style: const TextStyle(

                        color: Color(0xFFFFC861),

                        fontSize: 13,

                        fontWeight: FontWeight.w700,

                        height: 1.2,

                      ),

                    ),

                    const SizedBox(height: 4),

                  ],

                  if (message.replyPreview case final preview?) ...[

                    _ReplyPreview(

                      isMine: message.isMine,

                      sender: message.replySender,

                      preview: preview,

                    ),

                    const SizedBox(height: 7),

                  ],

                  _MeasuredMessageBody(

                    message: message,

                    style: _bodyStyle,

                    layout: layout,

                  ),

                ],

              ),

            ),

          ),

        );

        final config = actionConfig;

        return Align(

          alignment: message.isMine

              ? AlignmentDirectional.centerEnd

              : AlignmentDirectional.centerStart,

          child: Padding(

            padding: groupedInset,

            child: config == null || !config.hasContent

                ? bubble

                : MessageActionTarget(
                  config: config,
                  child: MessageSwipeActionTarget(
                    config: config,
                    child: bubble,
                  ),
                ),

          ),

        );

      },

    );

  }

  double _supplementaryContentWidth(

    BuildContext context, {

    required double maximumWidth,

  }) {

    var width = 0.0;

    final direction = Directionality.of(context);

    final scaler = MediaQuery.textScalerOf(context);

    final locale = Localizations.maybeLocaleOf(context);

    double measure(String value, TextStyle style) {

      final painter = TextPainter(

        text: TextSpan(text: value.replaceAll('\n', ' '), style: style),

        textDirection: direction,

        textScaler: scaler,

        locale: locale,

        maxLines: 1,

      )..layout();

      final measured = painter.width;

      painter.dispose();

      return measured;

    }

    if (message.senderName?.trim() case final sender? when sender.isNotEmpty) {

      width = math.max(

        width,

        measure(

          sender,

          const TextStyle(

            fontFamily: WrytteTypography.primaryFontFamily,

            fontSize: 13,

            fontWeight: FontWeight.w700,

          ),

        ),

      );

    }

    if (message.replyPreview?.trim() case final preview?

        when preview.isNotEmpty) {

      final sender = message.replySender?.trim() ?? '';

      final previewTextWidth = measure(

        preview,

        const TextStyle(

          fontFamily: WrytteTypography.primaryFontFamily,

          fontSize: 12,

          height: 1.25,

        ),

      );

      final senderWidth = sender.isEmpty

          ? 0.0

          : measure(

              sender,

              const TextStyle(

                fontFamily: WrytteTypography.primaryFontFamily,

                fontSize: 12,

                fontWeight: FontWeight.w700,

              ),

            );

      // Preview padding, indicator, and gaps occupy 29 logical pixels.

      width = math.max(width, math.max(previewTextWidth, senderWidth) + 29);

      width = math.max(width, math.min(160.0, maximumWidth));

    }

    return width.clamp(0.0, maximumWidth).toDouble();

  }

}

class _MeasuredMessageBody extends StatelessWidget {

  const _MeasuredMessageBody({

    required this.message,

    required this.style,

    required this.layout,

  });

  final ChatMessagePresentation message;

  final TextStyle style;

  final _ResolvedTextLayout layout;

  @override

  Widget build(BuildContext context) {

    final direction = Directionality.of(context);

    final scaler = MediaQuery.textScalerOf(context);

    final locale = Localizations.maybeLocaleOf(context);

    final bodySpan = TextSpan(text: message.text ?? '', style: style);

    if (!layout.metadataIsInline) {

      return Column(

        mainAxisSize: MainAxisSize.min,

        crossAxisAlignment: CrossAxisAlignment.stretch,

        children: [

          Text.rich(

            bodySpan,

            textDirection: direction,

            textScaler: scaler,

            locale: locale,

            textAlign: TextAlign.start,

          ),

          const SizedBox(height: 3),

          Align(

            alignment: Alignment.centerRight,

            child: _rightAlignedMetadata(),

          ),

        ],

      );

    }

    // Metadata fits on the final text line.

    //

    // The resolver has already proved that:

    //

    //   finalLineWidth + gap + effectiveMetadataFootprint <= contentWidth

    //

    // Keep the text paragraph untouched and paint metadata into that proven

    // free space. This avoids two different layout systems fighting each

    // other (WidgetSpan for multiline / Row for single-line).

    return Stack(

      fit: StackFit.passthrough,

      clipBehavior: Clip.none,

      children: [

        Text.rich(

          bodySpan,

          textDirection: direction,

          textScaler: scaler,

          locale: locale,

          textAlign: TextAlign.start,

        ),

        Positioned(

          right: 0,

          bottom: 0,

          child: _rightAlignedMetadata(),

        ),

      ],

    );

  }

  Widget _rightAlignedMetadata() {

    return Transform.translate(

      offset: Offset(

        message.isMine

            ? TextMessageBubble._outgoingMetadataPaintShift

            : 0,

        0,

      ),

      child: MessageMetadata(message: message),

    );

  }

}

class _ReplyPreview extends StatelessWidget {

  const _ReplyPreview({

    required this.isMine,

    required this.sender,

    required this.preview,

  });

  final bool isMine;

  final String? sender;

  final String preview;

  @override

  Widget build(BuildContext context) {

    return Container(

      width: double.infinity,

      padding: const EdgeInsetsDirectional.fromSTEB(9, 7, 9, 7),

      decoration: BoxDecoration(

        color: Colors.black.withValues(alpha: isMine ? .12 : .18),

        borderRadius: BorderRadius.circular(14),

        border: Border.all(

          color: Colors.white.withValues(alpha: isMine ? .15 : .08),

          width: .7,

        ),

      ),

      clipBehavior: Clip.antiAlias,

      child: Row(

        children: [

          Container(

            width: 3,

            height: 34,

            decoration: BoxDecoration(

              borderRadius: BorderRadius.circular(3),

              gradient: LinearGradient(

                begin: Alignment.topCenter,

                end: Alignment.bottomCenter,

                colors: isMine

                    ? [

                        Colors.white.withValues(alpha: .78),

                        Colors.white.withValues(alpha: .38),

                      ]

                    : const [Color(0xFF82C4FF), WrytteColors.primary],

              ),

            ),

          ),

          const SizedBox(width: 8),

          Expanded(

            child: Column(

              mainAxisSize: MainAxisSize.min,

              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                if (sender?.trim() case final senderName?

                    when senderName.isNotEmpty)

                  Text(

                    senderName,

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    style: TextStyle(

                      color: isMine

                          ? Colors.white.withValues(alpha: .88)

                          : const Color(0xFFB8DCFF),

                      fontSize: 12,

                      fontWeight: FontWeight.w700,

                    ),

                  ),

                Text(

                  preview,

                  maxLines: 2,

                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(

                    color: Colors.white.withValues(alpha: .70),

                    fontSize: 12,

                    height: 1.25,

                  ),

                ),

              ],

            ),

          ),

        ],

      ),

    );

  }

}

class _ResolvedTextLayout {

  const _ResolvedTextLayout({

    required this.width,

    required this.metadataIsInline,

    required this.metadataReservation,

    required this.metadataGap,

    required this.bodyIsSingleLine,

  });

  final double width;

  final bool metadataIsInline;

  final double metadataReservation;

  final double metadataGap;

  final bool bodyIsSingleLine;

}

class _TextLayoutResolver {

  static final LinkedHashMap<_TextLayoutCacheKey, _ResolvedTextLayout> _cache =

      LinkedHashMap<_TextLayoutCacheKey, _ResolvedTextLayout>();

  static const int _maximumCacheEntries = 300;

  static const double _tolerance = .05;

  static _ResolvedTextLayout resolve({

    required BuildContext context,

    required ChatMessagePresentation message,

    required TextStyle style,

    required double maximumWidth,

    required double metadataWidth,

  }) {

    final direction = Directionality.of(context);

    final scaler = MediaQuery.textScalerOf(context);

    final locale = Localizations.maybeLocaleOf(context);

    // Transform.translate changes paint position, not layout size. Outgoing

    // metadata paints 5px into the trailing content padding, so only the

    // remaining width belongs to the text-content footprint.

    final metadataPaintShift = message.isMine

        ? TextMessageBubble._outgoingMetadataPaintShift

        : 0.0;

    final metadataFootprintWidth = math.max(

      0.0,

      metadataWidth - metadataPaintShift,

    );

    // Static resolver caches survive hot reload. Bump this whenever the fit

    // algorithm changes so an old metadataIsInline result cannot be reused.

    const layoutRevision = 2;

    final key = _TextLayoutCacheKey(

      id: '$layoutRevision:${message.id}',

      text: message.text ?? '',

      widthBucket: (maximumWidth * 2).round(),

      bodyScaleBucket: (scaler.scale(16) * 20).round(),

      metadataScaleBucket: (scaler.scale(11) * 20).round(),

      locale: locale?.toLanguageTag() ?? '',

      direction: direction,

      metadataBucket: (metadataFootprintWidth * 2).round(),

      edited: message.edited,

      deliveryState: message.deliveryState,

    );

    final cached = _cache.remove(key);

    if (cached != null) {

      _cache[key] = cached;

      return cached;

    }

    final resolved = _measure(

      text: message.text ?? '',

      style: style,

      maximumWidth: maximumWidth,

      metadataWidth: metadataFootprintWidth,

      direction: direction,

      scaler: scaler,

      locale: locale,

    );

    _cache[key] = resolved;

    if (_cache.length > _maximumCacheEntries) {

      _cache.remove(_cache.keys.first);

    }

    return resolved;

  }

  static _ResolvedTextLayout _measure({

    required String text,

    required TextStyle style,

    required double maximumWidth,

    required double metadataWidth,

    required TextDirection direction,

    required TextScaler scaler,

    required Locale? locale,

  }) {

    if (maximumWidth <= 0) {

      return const _ResolvedTextLayout(

        width: 0,

        metadataIsInline: false,

        metadataReservation: 0,

        metadataGap: 0,

        bodyIsSingleLine: false,

      );

    }

    final painter = TextPainter(

      text: TextSpan(text: text, style: style),

      textDirection: direction,

      textScaler: scaler,

      locale: locale,

      textWidthBasis: TextWidthBasis.longestLine,

    )..layout(maxWidth: maximumWidth);

    final lines = painter.computeLineMetrics();

    final widestLine = lines.fold<double>(

      0,

      (widest, line) => math.max(widest, line.width),

    );

    final finalLine = lines.isEmpty ? 0.0 : lines.last.width;

    final lineCount = lines.length;

    final hasForcedTrailingLine = text.endsWith('\n');

    var inline = false;

    var gap = TextMessageBubble._preferredMetadataGap;

    if (!hasForcedTrailingLine && lines.isNotEmpty) {

      inline = finalLine + gap + metadataWidth <= maximumWidth + _tolerance;

      if (!inline &&

          finalLine + TextMessageBubble._minimumMetadataGap + metadataWidth <=

              maximumWidth + _tolerance) {

        gap = TextMessageBubble._minimumMetadataGap;

        inline = true;

      }

    }

    final inlineWidthSlack = lineCount == 1 ? 2.0 : 0.0;

    var desiredWidth = inline

        ? math.max(

            widestLine,

            finalLine + gap + metadataWidth + inlineWidthSlack,

          )

        : math.max(widestLine, metadataWidth);

    desiredWidth = desiredWidth.clamp(0.0, maximumWidth).toDouble();

    // Narrowing to the natural width must not redistribute words. If it does,

    // retain Flutter's original max-width line breaks for a stable bubble.

    painter.layout(maxWidth: desiredWidth);

    final narrowedLines = painter.computeLineMetrics();

    final narrowedFinal = narrowedLines.isEmpty

        ? 0.0

        : narrowedLines.last.width;

    final preservesLayout = narrowedLines.length == lineCount;

    final inlineStillFits =

        !inline ||

        narrowedFinal + gap + metadataWidth <= desiredWidth + _tolerance;

    if (!preservesLayout || !inlineStillFits) desiredWidth = maximumWidth;

    painter.dispose();

    return _ResolvedTextLayout(

      width: desiredWidth,

      metadataIsInline: inline,

      metadataReservation: inline ? gap + metadataWidth : 0,

      metadataGap: inline ? gap : 0,

      bodyIsSingleLine: lineCount == 1,

    );

  }

}

class _TextLayoutCacheKey {

  const _TextLayoutCacheKey({

    required this.id,

    required this.text,

    required this.widthBucket,

    required this.bodyScaleBucket,

    required this.metadataScaleBucket,

    required this.locale,

    required this.direction,

    required this.metadataBucket,

    required this.edited,

    required this.deliveryState,

  });

  final String id;

  final String text;

  final int widthBucket;

  final int bodyScaleBucket;

  final int metadataScaleBucket;

  final String locale;

  final TextDirection direction;

  final int metadataBucket;

  final bool edited;

  final ChatDeliveryState deliveryState;

  @override

  bool operator ==(Object other) {

    return other is _TextLayoutCacheKey &&

        other.id == id &&

        other.text == text &&

        other.widthBucket == widthBucket &&

        other.bodyScaleBucket == bodyScaleBucket &&

        other.metadataScaleBucket == metadataScaleBucket &&

        other.locale == locale &&

        other.direction == direction &&

        other.metadataBucket == metadataBucket &&

        other.edited == edited &&

        other.deliveryState == deliveryState;

  }

  @override

  int get hashCode => Object.hash(

    id,

    text,

    widthBucket,

    bodyScaleBucket,

    metadataScaleBucket,

    locale,

    direction,

    metadataBucket,

    edited,

    deliveryState,

  );

}
