class Country {
  const Country({
    required this.isoCode,
    required this.name,
    required this.dialCode,
    required this.flag,
  });

  final String isoCode;
  final String name;
  final String dialCode;
  final String flag;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Country &&
          other.isoCode == isoCode &&
          other.dialCode == dialCode;

  @override
  int get hashCode => Object.hash(isoCode, dialCode);
}
