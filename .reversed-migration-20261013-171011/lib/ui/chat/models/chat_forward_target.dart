class ChatForwardTarget {
  const ChatForwardTarget({
    required this.id,
    required this.title,
    required this.subtitle,
    this.receiverId,
    this.conversationId,
    this.avatarUrl,
    this.isSavedContact = true,
  });

  final String id;
  final String title;
  final String subtitle;

  // These are intentionally present now so the UI does not need to change
  // when dummy contacts are replaced by real forwarding targets later.
  final String? receiverId;
  final String? conversationId;
  final String? avatarUrl;
  final bool isSavedContact;
}
