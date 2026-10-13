enum ChatConversationKind { direct, group, community }

class ChatScreenConfig {
  const ChatScreenConfig({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.kind,
    this.avatarAsset = 'assets/images/default_avatar.jpg',
    this.callsAvailable = true,
  });

  const ChatScreenConfig.preview()
    : id = 'preview-chat',
      title = 'Wrytte Team',
      subtitle = 'Online',
      kind = ChatConversationKind.direct,
      avatarAsset = 'assets/images/default_avatar.jpg',
      callsAvailable = true;

  final String id;
  final String title;
  final String subtitle;
  final ChatConversationKind kind;
  final String avatarAsset;
  final bool callsAvailable;
}
