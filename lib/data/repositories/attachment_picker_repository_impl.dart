import 'package:wrytte/data/services/device_attachment_picker_service.dart';
import 'package:wrytte/domain/models/attachment_contact_page.dart';
import 'package:wrytte/domain/models/picked_attachment_file.dart';
import 'package:wrytte/domain/repositories/attachment_picker_repository.dart';

class AttachmentPickerRepositoryImpl implements AttachmentPickerRepository {
  AttachmentPickerRepositoryImpl(this._service);

  final DeviceAttachmentPickerService _service;

  @override
  Future<List<PickedAttachmentFile>> pickFiles({bool audioOnly = false}) =>
      _service.pickFiles(audioOnly: audioOnly);

  @override
  Future<AttachmentContactPage> loadContacts() => _service.loadContacts();

  @override
  Future<void> openContactsSettings() => _service.openContactsSettings();
}
