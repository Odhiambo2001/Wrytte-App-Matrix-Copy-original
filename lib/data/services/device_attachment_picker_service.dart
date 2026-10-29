import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wrytte/domain/models/attachment_contact.dart';
import 'package:wrytte/domain/models/attachment_contact_page.dart';
import 'package:wrytte/domain/models/picked_attachment_file.dart';

class DeviceAttachmentPickerService {
  Future<List<PickedAttachmentFile>> pickFiles({bool audioOnly = false}) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: audioOnly ? 'Choose audio' : 'Choose files',
      type: audioOnly ? FileType.audio : FileType.any,
      allowMultiple: true,
      withData: false,
    );
    final selected = <PickedAttachmentFile>[];
    if (result == null) return selected;
    for (final file in result.files) {
      final path = await _materializePath(file);
      selected.add(
        PickedAttachmentFile(
          path: path,
          name: file.name,
          sizeBytes: file.size,
        ),
      );
    }
    return selected;
  }

  Future<String> _materializePath(PlatformFile file) async {
    final directPath = file.path;
    if (directPath != null && directPath.isNotEmpty) return directPath;

    // Android's Storage Access Framework commonly returns a content URI, not
    // a filesystem path. Stream it to app-owned temporary storage so later
    // upload/playback code never depends on a short-lived URI grant.
    final directory = await getTemporaryDirectory();
    final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final output = File(
      '${directory.path}${Platform.pathSeparator}wrytte_attachment_${DateTime.now().microsecondsSinceEpoch}_$safeName',
    );
    final sink = output.openWrite();
    try {
      final stream = file.readStream;
      final bytes = file.bytes;
      if (stream != null) {
        await sink.addStream(stream);
      } else if (bytes != null) {
        sink.add(bytes);
      } else {
        throw StateError('The selected file could not be read: ${file.name}');
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return output.path;
  }

  Future<AttachmentContactPage> loadContacts() async {
    final permission = await Permission.contacts.request();
    if (!permission.isGranted) {
      return const AttachmentContactPage(contacts: [], accessDenied: true);
    }
    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );
    final summaries =
        <AttachmentContact>[
          for (final contact in contacts)
            if (contact.phones.isNotEmpty)
              AttachmentContact(
                id: contact.id,
                displayName: contact.displayName.trim().isNotEmpty
                    ? contact.displayName.trim()
                    : 'Unnamed contact',
                phoneNumber: contact.phones.first.number,
              ),
        ]..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
    return AttachmentContactPage(
      contacts: List.unmodifiable(summaries),
      accessDenied: false,
    );
  }

  Future<void> openContactsSettings() =>
      openAppSettings();
}
