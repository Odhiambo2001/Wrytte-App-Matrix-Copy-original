class ChatMediaEditorResult {
  const ChatMediaEditorResult({
    required this.assetId,
    required this.originalFilePath,
    required this.editedFilePath,
  });

  final String assetId;
  final String originalFilePath;
  final String? editedFilePath;

  bool get wasEdited => editedFilePath != null;
}
