import 'package:wrytte/domain/models/country.dart';

abstract interface class CountryRepository {
  Future<List<Country>> getCountries();
}
