import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────
//  LOCATION SERVICE
//  Provides city/state/country for AI context.
//  - Fixes driver-seat orientation (LHD vs RHD countries)
//  - Enables local labor rate estimates
//  - Only city + state level — no precise coords stored/sent
// ─────────────────────────────────────────────────────────────

class LocationInfo {
  final String city;
  final String state;
  final String country;
  final String countryCode; // e.g. "US", "GB", "AU"

  const LocationInfo({
    required this.city,
    required this.state,
    required this.country,
    required this.countryCode,
  });

  /// Whether vehicles in this country are left-hand drive (driver on left).
  bool get isLHD {
    // RHD countries — driver on RIGHT side of car
    const rhdCountries = {
      'GB', 'AU', 'NZ', 'JP', 'ZA', 'IN', 'PK', 'BD', 'LK',
      'MY', 'SG', 'HK', 'TH', 'ID', 'KE', 'TZ', 'UG', 'ZW',
      'ZM', 'BW', 'NA', 'MW', 'MZ', 'NG', 'GH', 'IE', 'MT',
      'CY', 'JM', 'BB', 'TT', 'GY', 'BN', 'MV', 'MU', 'SC',
    };
    return !rhdCountries.contains(countryCode.toUpperCase());
  }

  /// Driver seat description for AI prompts.
  String get driverSideDescription =>
      isLHD ? 'left side (driver on left, USA standard)' : 'right side (driver on right)';

  /// Formatted location string for AI prompt — city + state/region + country.
  String get aiContextString {
    final parts = <String>[];
    if (city.isNotEmpty) parts.add(city);
    if (state.isNotEmpty) parts.add(state);
    if (country.isNotEmpty) parts.add(country);
    return parts.join(', ');
  }

  /// Returns a brief note about approximate labor rates for this region.
  String get laborRateHint {
    switch (countryCode.toUpperCase()) {
      case 'US':
      // US labor rates vary heavily by state — give regional hint
        const highCostStates = {
          'CA', 'NY', 'WA', 'MA', 'CO', 'OR', 'CT', 'NJ', 'HI', 'AK'
        };
        final stateCode = _usStateCode(state);
        if (highCostStates.contains(stateCode)) {
          return 'US high-cost state (\$150–\$200+/hr shop rate typical)';
        }
        return 'US (\$100–\$150/hr shop rate typical)';
      case 'CA':
        return 'Canada (\$120–\$160 CAD/hr typical)';
      case 'GB':
        return 'UK (£80–£120/hr typical)';
      case 'AU':
        return 'Australia (\$150–\$200 AUD/hr typical)';
      case 'NZ':
        return 'New Zealand (\$120–\$180 NZD/hr typical)';
      default:
        return country.isNotEmpty ? country : 'Unknown region';
    }
  }

  static String _usStateCode(String stateName) {
    const map = {
      'Alabama': 'AL', 'Alaska': 'AK', 'Arizona': 'AZ', 'Arkansas': 'AR',
      'California': 'CA', 'Colorado': 'CO', 'Connecticut': 'CT',
      'Delaware': 'DE', 'Florida': 'FL', 'Georgia': 'GA', 'Hawaii': 'HI',
      'Idaho': 'ID', 'Illinois': 'IL', 'Indiana': 'IN', 'Iowa': 'IA',
      'Kansas': 'KS', 'Kentucky': 'KY', 'Louisiana': 'LA', 'Maine': 'ME',
      'Maryland': 'MD', 'Massachusetts': 'MA', 'Michigan': 'MI',
      'Minnesota': 'MN', 'Mississippi': 'MS', 'Missouri': 'MO',
      'Montana': 'MT', 'Nebraska': 'NE', 'Nevada': 'NV',
      'New Hampshire': 'NH', 'New Jersey': 'NJ', 'New Mexico': 'NM',
      'New York': 'NY', 'North Carolina': 'NC', 'North Dakota': 'ND',
      'Ohio': 'OH', 'Oklahoma': 'OK', 'Oregon': 'OR', 'Pennsylvania': 'PA',
      'Rhode Island': 'RI', 'South Carolina': 'SC', 'South Dakota': 'SD',
      'Tennessee': 'TN', 'Texas': 'TX', 'Utah': 'UT', 'Vermont': 'VT',
      'Virginia': 'VA', 'Washington': 'WA', 'West Virginia': 'WV',
      'Wisconsin': 'WI', 'Wyoming': 'WY',
    };
    return map[stateName] ?? stateName.toUpperCase().substring(0, 2);
  }

  static const LocationInfo unknown = LocationInfo(
    city: '', state: '', country: '', countryCode: 'US',
  );
}

class LocationService {
  static LocationInfo? _cached;
  static DateTime? _cacheTime;

  /// Fetches city/state/country. Caches for 10 minutes.
  /// Returns null if permission denied or unavailable.
  static Future<LocationInfo?> getLocation() async {
    // Return cache if fresh
    if (_cached != null && _cacheTime != null &&
        DateTime.now().difference(_cacheTime!).inMinutes < 10) {
      return _cached;
    }

    try {
      // Check permission
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        debugPrint('Location permission denied');
        return null;
      }

      // Check if location services are enabled
      if (!await Geolocator.isLocationServiceEnabled()) {
        debugPrint('Location services disabled');
        return null;
      }

      // Get position — low accuracy is fine, we just need city level
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 8),
        ),
      );

      // Reverse geocode to city/state/country
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isEmpty) return null;

      final p = placemarks.first;
      final info = LocationInfo(
        city: p.locality ?? p.subAdministrativeArea ?? '',
        state: p.administrativeArea ?? '',
        country: p.country ?? '',
        countryCode: p.isoCountryCode ?? 'US',
      );

      _cached = info;
      _cacheTime = DateTime.now();
      debugPrint('Location: ${info.aiContextString} (${info.countryCode})');
      return info;

    } catch (e) {
      debugPrint('Location error: $e');
      return null;
    }
  }

  /// Clears the cache (e.g. if user travels).
  static void clearCache() {
    _cached = null;
    _cacheTime = null;
  }
}