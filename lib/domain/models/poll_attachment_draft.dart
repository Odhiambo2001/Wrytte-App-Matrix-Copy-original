class PollAttachmentDraft {
  const PollAttachmentDraft({
    required this.question,
    required this.options,
    this.description,
    this.allowMultipleAnswers = false,
  });

  final String question;
  final List<String> options;
  final String? description;
  final bool allowMultipleAnswers;
}
