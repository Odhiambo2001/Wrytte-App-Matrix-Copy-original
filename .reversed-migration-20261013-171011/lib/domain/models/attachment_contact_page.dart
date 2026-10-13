import 'package:wrytte/domain/models/attachment_contact.dart';

class AttachmentContactPage {
  const AttachmentContactPage({
    required this.contacts,
    required this.accessDenied,
  });

  final List<AttachmentContact> contacts;
  final bool accessDenied;
}
