enum ChatAttachmentTab { gallery, file, location, poll, contact }

extension ChatAttachmentTabLabel on ChatAttachmentTab {
  String get label => switch (this) {
    ChatAttachmentTab.gallery => 'Gallery',
    ChatAttachmentTab.file => 'File',
    ChatAttachmentTab.location => 'Location',
    ChatAttachmentTab.poll => 'Poll',
    ChatAttachmentTab.contact => 'Contact',
  };
}
