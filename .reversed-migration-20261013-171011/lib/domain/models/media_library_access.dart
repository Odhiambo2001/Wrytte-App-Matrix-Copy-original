enum MediaLibraryAccess { unknown, full, limited, denied, restricted }

extension MediaLibraryAccessX on MediaLibraryAccess {
  bool get canRead =>
      this == MediaLibraryAccess.full || this == MediaLibraryAccess.limited;
}
