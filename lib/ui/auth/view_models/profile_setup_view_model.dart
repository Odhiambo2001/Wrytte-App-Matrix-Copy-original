import 'package:flutter/foundation.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/models/camera_capture_result.dart';

class ProfileSetupViewModel extends ChangeNotifier {
  String _name = '';
  bool _syncContacts = true;
  MediaAsset? _profilePhoto;
  CameraCaptureResult? _capturedProfilePhoto;
  String? _preparedProfilePhotoPath;

  String get name => _name;
  bool get syncContacts => _syncContacts;
  MediaAsset? get profilePhoto => _profilePhoto;
  CameraCaptureResult? get capturedProfilePhoto => _capturedProfilePhoto;
  String? get preparedProfilePhotoPath => _preparedProfilePhotoPath;
  String? get profilePhotoPath =>
      _preparedProfilePhotoPath ?? _capturedProfilePhoto?.path;
  bool get hasProfilePhoto => _profilePhoto != null || profilePhotoPath != null;
  bool get canFinish => _name.trim().isNotEmpty;

  void changeName(String value) {
    if (value == _name) return;
    _name = value;
    notifyListeners();
  }

  void setSyncContacts(bool value) {
    if (value == _syncContacts) return;
    _syncContacts = value;
    notifyListeners();
  }

  void setProfilePhoto(MediaAsset asset) {
    if (_profilePhoto?.id == asset.id && _capturedProfilePhoto == null) return;
    _profilePhoto = asset;
    _capturedProfilePhoto = null;
    _preparedProfilePhotoPath = null;
    notifyListeners();
  }

  void setCapturedProfilePhoto(CameraCaptureResult capture) {
    if (_capturedProfilePhoto?.path == capture.path) return;
    _capturedProfilePhoto = capture;
    _profilePhoto = null;
    _preparedProfilePhotoPath = null;
    notifyListeners();
  }

  void setPreparedProfilePhoto(String path) {
    if (_preparedProfilePhotoPath == path &&
        _profilePhoto == null &&
        _capturedProfilePhoto == null) {
      return;
    }
    _preparedProfilePhotoPath = path;
    _profilePhoto = null;
    _capturedProfilePhoto = null;
    notifyListeners();
  }

  void clearProfilePhoto() {
    if (!hasProfilePhoto) return;
    _profilePhoto = null;
    _capturedProfilePhoto = null;
    _preparedProfilePhotoPath = null;
    notifyListeners();
  }
}
