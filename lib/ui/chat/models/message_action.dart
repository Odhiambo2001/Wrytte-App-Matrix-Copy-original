import 'dart:async';

import 'package:flutter/foundation.dart';

enum MessageActionType {
  reply,
  copy,
  forward,
  save,
  edit,
  editMedia,
  pin,
  delete,
  select,
}

@immutable
class MessageAction {
  const MessageAction({
    required this.type,
    required this.label,
    this.svgAsset,
    this.iconScale = 1,
    this.mirrorSvgHorizontally = false,
    this.isDestructive = false,
    this.isEnabled = true,
  });

  const MessageAction.reply()
    : type = MessageActionType.reply,
      label = 'Reply',
      svgAsset = 'assets/svg/Forward Icon.svg',
      iconScale = 1.18,
      mirrorSvgHorizontally = true,
      isDestructive = false,
      isEnabled = true;

  const MessageAction.copy()
    : type = MessageActionType.copy,
      label = 'Copy',
      svgAsset = 'assets/svg/Copy icon.svg',
      iconScale = 1.03,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  const MessageAction.forward()
    : type = MessageActionType.forward,
      label = 'Forward',
      svgAsset = 'assets/svg/Forward Icon.svg',
      iconScale = 1.18,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  const MessageAction.save()
    : type = MessageActionType.save,
      label = 'Save',
      svgAsset = 'assets/svg/Download Save icon.svg',
      iconScale = 1.26,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  const MessageAction.edit()
    : type = MessageActionType.edit,
      label = 'Edit',
      svgAsset = 'assets/svg/Edit pencil icon.svg',
      iconScale = 1.02,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  /// Full media editing from the viewer. Kept distinct from caption/message
  /// editing so the long-press menu can retain the old Wrytte behaviour.
  const MessageAction.editMedia()
    : type = MessageActionType.editMedia,
      label = 'Edit',
      svgAsset = 'assets/svg/Edit pencil icon.svg',
      iconScale = 1.02,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  const MessageAction.pin()
    : type = MessageActionType.pin,
      label = 'Pin',
      svgAsset = 'assets/svg/Pin icon .svg',
      iconScale = 1.12,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  const MessageAction.unpin()
    : type = MessageActionType.pin,
      label = 'Unpin',
      svgAsset = 'assets/svg/Unpin icon .svg',
      iconScale = 1.12,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  const MessageAction.delete()
    : type = MessageActionType.delete,
      label = 'Delete',
      svgAsset = 'assets/svg/Delete icon.svg',
      iconScale = 1.16,
      mirrorSvgHorizontally = false,
      isDestructive = true,
      isEnabled = true;

  const MessageAction.select()
    : type = MessageActionType.select,
      label = 'Select',
      svgAsset = 'assets/svg/Select icon.svg',
      iconScale = 1.08,
      mirrorSvgHorizontally = false,
      isDestructive = false,
      isEnabled = true;

  final MessageActionType type;
  final String label;
  final String? svgAsset;
  final double iconScale;
  final bool mirrorSvgHorizontally;
  final bool isDestructive;
  final bool isEnabled;
}

typedef MessageActionHandler = FutureOr<void> Function(MessageAction action);
typedef MessageReactionHandler = FutureOr<void> Function(String reaction);
typedef MessageMoreReactionsHandler = FutureOr<void> Function();

@immutable
class MessageActionConfig {
  const MessageActionConfig({
    required this.actions,
    this.reactions = const ['❤️', '👍', '👎', '🔥', '🥰', '👏'],
    this.onActionSelected,
    this.onReactionSelected,
    this.onMoreReactions,
    this.alignMenuRight,
    this.usePinChoices = false,
    this.useDeleteChoices = true,
    this.canDeleteForEveryone = false,
  });

  final List<MessageAction> actions;
  final List<String> reactions;
  final MessageActionHandler? onActionSelected;
  final MessageReactionHandler? onReactionSelected;
  final MessageMoreReactionsHandler? onMoreReactions;
  final bool? alignMenuRight;
  final bool usePinChoices;
  final bool useDeleteChoices;
  final bool canDeleteForEveryone;

  bool get hasContent =>
      actions.isNotEmpty || reactions.isNotEmpty || onMoreReactions != null;
}
