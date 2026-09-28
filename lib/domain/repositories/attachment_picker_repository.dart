import 'package:wrytte/domain/models/attachment_contact_page.dart';
import 'package:wrytte/domain/models/picked_attachment_file.dart';

abstract interface class AttachmentPickerRepository {
  Future<List<PickedAttachmentFile>> pickFiles({bool audioOnly = false});
  Future<AttachmentContactPage> loadContacts();
  Future<void> openContactsSettings();
}
