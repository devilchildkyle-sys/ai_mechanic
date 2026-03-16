import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart'
as classic;
import 'main.dart';
import 'config.dart';
import 'pid_definitions.dart';
import 'ai_overview_screen.dart';
import 'debug_screen.dart';
import 'history_screen.dart';
import 'stats_screen.dart';
import 'settings_screen.dart';

// ─────────────────────────────────────────
//  VEHICLE DATA MODEL
// ─────────────────────────────────────────
class VehicleProfile {
  final String vin;
  final String year;
  final String make;
  final String model;
  final String engine;
  final String fuelType;
  final String transmission;
  final bool engineRunning;
  final Map<String, String> rawObd;

  VehicleProfile({
    required this.vin,
    required this.year,
    required this.make,
    required this.model,
    required this.engine,
    required this.fuelType,
    required this.transmission,
    required this.engineRunning,
    required this.rawObd,
  });

  String get displayName => '$year $make $model';
  String get engineDisplay => '$engine · $fuelType';

  Map<String, dynamic> toJson() => {
    'vin': vin,
    'year': year,
    'make': make,
    'model': model,
    'engine': engine,
    'fuelType': fuelType,
    'transmission': transmission,
    'engineRunning': engineRunning,
    'rawObd': rawObd,
    'scanTime': DateTime.now().toIso8601String(),
  };
}

// ─────────────────────────────────────────
//  SUPPORTED PID SET
// ─────────────────────────────────────────
class SupportedPids {
  final Set<String> pids;
  SupportedPids(this.pids);

  bool has(String pid) => pids.contains(pid.toUpperCase());

  static SupportedPids fromBitmask(String hex0100, String hex0120) {
    final supported = <String>{};
    try {
      _parseBitmask(hex0100, 0x01, supported);
      _parseBitmask(hex0120, 0x21, supported);
    } catch (_) {}
    return SupportedPids(supported);
  }

  static void _parseBitmask(String hex, int startPid, Set<String> out) {
    if (hex.length < 8) return;
    final value = int.parse(hex.substring(0, 8), radix: 16);
    for (int bit = 0; bit < 32; bit++) {
      if ((value >> (31 - bit)) & 1 == 1) {
        out.add((startPid + bit)
            .toRadixString(16)
            .padLeft(2, '0')
            .toUpperCase());
      }
    }
  }
}

// ─────────────────────────────────────────
//  OBD2 SERVICE — with command lock
// ─────────────────────────────────────────
class OBD2Service {
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  final List<int> _responseBuffer = [];
  bool _isClassic = false;  // true when connected via Classic BT RFCOMM

  // Command lock — prevents buffer bleed between rapid calls
  bool _busy = false;

  // Pause flag — set true while debug screen runs Powerstroke tests
  // so the live update timer skips its cycle rather than blasting the
  // CAN bus while Mode 22 queries are in progress.
  bool _paused = false;
  void pauseLiveUpdates()  { _paused = true; }
  void resumeLiveUpdates() { _paused = false; }

  SupportedPids? supportedPids;

  static const String _veepeakService = '0000fff0-0000-1000-8000-00805f9b34fb';
  static const String _veepeakWrite   = '0000fff2-0000-1000-8000-00805f9b34fb';
  static const String _veepeakNotify  = '0000fff1-0000-1000-8000-00805f9b34fb';

  Future<bool> initialize(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();

      for (final service in services) {
        final sid = service.serviceUuid.toString().toLowerCase();
        if (sid == _veepeakService) {
          for (final char in service.characteristics) {
            final cid = char.characteristicUuid.toString().toLowerCase();
            if (cid == _veepeakNotify && char.properties.notify) {
              _notifyChar = char;
            }
            if (cid == _veepeakWrite &&
                (char.properties.write ||
                    char.properties.writeWithoutResponse)) {
              _writeChar = char;
            }
          }
        }
        if (_writeChar == null || _notifyChar == null) {
          for (final char in service.characteristics) {
            if (char.properties.notify) _notifyChar ??= char;
            if (char.properties.write ||
                char.properties.writeWithoutResponse) {
              _writeChar ??= char;
            }
          }
        }
      }

      if (_writeChar == null || _notifyChar == null) return false;

      await _notifyChar!.setNotifyValue(true);
      _notifyChar!.lastValueStream.listen((value) {
        _responseBuffer.addAll(value);
      });

      await _cmd('ATZ');
      await Future.delayed(const Duration(milliseconds: 1000));
      await _cmd('ATE0');
      await _cmd('ATL0');
      await _cmd('ATS0');
      await _cmd('ATH0');
      await _cmd('ATSP0');
      await Future.delayed(const Duration(milliseconds: 500));
      return true;
    } catch (e) {
      debugPrint('OBD2 init error: $e');
      return false;
    }
  }

  // ── LOCKED COMMAND — only one at a time ──
  Future<String> _cmd(String command) async {
    // Wait for any in-progress command to finish (max 3s)
    int waited = 0;
    while (_busy && waited < 3000) {
      await Future.delayed(const Duration(milliseconds: 50));
      waited += 50;
    }

    if (_writeChar == null && !_isClassic) return '';
    _busy = true;
    try {
      _responseBuffer.clear();
      final bytes = utf8.encode('$command\r');
      if (_isClassic) {
        // Classic BT — write via RFCOMM serial stream
        _classicConnection?.output.add(bytes);
        await _classicConnection?.output.allSent;
      } else if (_writeChar!.properties.writeWithoutResponse) {
        await _writeChar!.write(bytes, withoutResponse: true);
      } else {
        await _writeChar!.write(bytes);
      }
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        final r = utf8.decode(_responseBuffer, allowMalformed: true);
        if (r.contains('>') ||
            r.contains('ERROR') ||
            r.contains('UNABLE') ||
            r.contains('NO DATA')) break;
      }
      return utf8.decode(_responseBuffer, allowMalformed: true).trim();
    } catch (e) {
      return '';
    } finally {
      _busy = false;
    }
  }

  /// Public wrapper for sending a raw command and getting the full response.
  /// Used by NovaByteAnalyst to capture unstripped byte samples.
  Future<String> sendRaw(String command) => _cmd(command);

  // ── CLASSIC BLUETOOTH INITIALIZE ─────────────────────────
  /// Connects to a Classic BT OBD2 adapter via RFCOMM SPP.
  /// Uses flutter_bluetooth_serial for the serial port connection.
  /// After connecting, runs the same ELM327 init sequence as BLE.
  Future<bool> initializeClassic(String macAddress) async {
    try {
      // Small settle delay — cheap adapters need a moment before accepting
      // a new RFCOMM connection, especially after the Bluetooth screen
      // scanned or listed paired devices.
      await Future.delayed(const Duration(milliseconds: 600));

      final classicLib = await _connectClassicRfcomm(macAddress);
      if (!classicLib) return false;

      // Run ELM327 init over the classic connection (same as BLE)
      await _cmd('ATZ');
      await Future.delayed(const Duration(milliseconds: 1000));
      await _cmd('ATE0');
      await _cmd('ATL0');
      await _cmd('ATS0');
      await _cmd('ATH0');
      await _cmd('ATSP0');
      await Future.delayed(const Duration(milliseconds: 500));
      return true;
    } catch (e) {
      debugPrint('Classic BT init error: $e');
      return false;
    }
  }

  classic.BluetoothConnection? _classicConnection;

  Future<bool> _connectClassicRfcomm(String mac) async {
    try {
      _classicConnection =
      await classic.BluetoothConnection.toAddress(mac)
          .timeout(const Duration(seconds: 15));

      // Route incoming classic data into our shared _responseBuffer
      _classicConnection!.input!.listen((data) {
        _responseBuffer.addAll(data);
      });

      // Override _writeChar to null — classic path uses _classicConnection
      _writeChar = null;
      _notifyChar = null;
      _isClassic = true;
      return true;
    } catch (e) {
      debugPrint('RFCOMM connect error: $e');
      return false;
    }
  }

  // ── DETECT SUPPORTED PIDs ─────────────
  Future<SupportedPids> detectSupportedPids() async {
    final r0100 = await _cmd('0100');
    final r0120 = await _cmd('0120');
    final hex0100 = _extractData(r0100);
    final hex0120 = _extractData(r0120);
    supportedPids = SupportedPids.fromBitmask(hex0100, hex0120);
    debugPrint('Supported PIDs: ${supportedPids!.pids}');
    return supportedPids!;
  }

  Future<String> readVin() async {
    final r = await _cmd('0902');
    return _parseVin(r);
  }

  String _parseVin(String raw) {
    try {
      final lines = raw.split(RegExp(r'[\r\n]'));
      final hexBuffer = StringBuffer();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed == '>') continue;
        String hexData = trimmed;
        if (RegExp(r'^\d:').hasMatch(hexData)) hexData = hexData.substring(2);
        hexData = hexData.replaceAll(RegExp(r'^490201'), '');
        hexData = hexData.replaceAll(RegExp(r'^4902'), '');
        hexBuffer.write(hexData);
      }
      final hexStr =
      hexBuffer.toString().replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      final vinChars = StringBuffer();
      for (int i = 0; i + 1 < hexStr.length; i += 2) {
        final byte = int.parse(hexStr.substring(i, i + 2), radix: 16);
        if (byte >= 32 && byte <= 126) vinChars.writeCharCode(byte);
      }
      final result = vinChars.toString().toUpperCase();
      final vinMatch = RegExp(r'[A-HJ-NPR-Z0-9]{17}').firstMatch(result);
      if (vinMatch != null) return vinMatch.group(0)!;
      if (result.length >= 10) return result;
    } catch (e) {
      debugPrint('VIN parse error: $e');
    }
    return 'UNKNOWN';
  }

  Future<int> readRpm() async {
    final r = await _cmd('010C');
    try {
      final hex = _extractData(r);
      if (hex.length >= 4) {
        final a = int.parse(hex.substring(0, 2), radix: 16);
        final b = int.parse(hex.substring(2, 4), radix: 16);
        return ((a * 256) + b) ~/ 4;
      }
    } catch (_) {}
    return 0;
  }

  Future<int> readCoolantTemp() async {
    final r = await _cmd('0105');
    try {
      final hex = _extractData(r);
      if (hex.length >= 2) {
        return int.parse(hex.substring(0, 2), radix: 16) - 40;
      }
    } catch (_) {}
    return 0;
  }

  Future<int> readSpeed() async {
    final r = await _cmd('010D');
    try {
      final hex = _extractData(r);
      if (hex.length >= 2) {
        return int.parse(hex.substring(0, 2), radix: 16);
      }
    } catch (_) {}
    return 0;
  }

  Future<double> readThrottle() async {
    final r = await _cmd('0111');
    try {
      final hex = _extractData(r);
      if (hex.length >= 2) {
        return (int.parse(hex.substring(0, 2), radix: 16) * 100) / 255;
      }
    } catch (_) {}
    return 0;
  }

  Future<double> readFuelLevel() async {
    final r = await _cmd('012F');
    try {
      final hex = _extractData(r);
      if (hex.length >= 2) {
        return (int.parse(hex.substring(0, 2), radix: 16) * 100) / 255;
      }
    } catch (_) {}
    return 0;
  }

  Future<double> readBattery() async {
    final r = await _cmd('ATRV');
    try {
      // Strict match: 1-2 digits, dot, 1 digit, followed by V
      // e.g. "12.4V" or "9.8V" — avoids grabbing garbage from buffer
      final match = RegExp(r'\b(\d{1,2}\.\d)V\b').firstMatch(r);
      if (match != null) {
        final v = double.parse(match.group(1)!);
        if (v >= 8.0 && v <= 18.0) return v;
      }
    } catch (_) {}
    return 0;
  }

  Future<List<String>> readDtcs() async {
    // Step 1: Pipe cleaner — _cmd() clears buffer, sends 0100, waits for '>'.
    // Any stale Mode 22 bytes get consumed here rather than contaminating
    // the DTC response.
    await _cmd('0100');
    await Future.delayed(const Duration(milliseconds: 150));
    await drainAdapter();

    // Step 2: Enable spaces in responses (ATS1) so the parser can reliably
    // split bytes. ATS0 (no spaces) is the default we use for PID reads,
    // but it breaks token-based parsing of Mode 03 responses.
    // We restore ATS0 after reading.
    await _cmd('ATS1');

    // Step 3: Mode 03 — buffer cleared, waits for '>'.
    final raw = await _cmd('03');

    // Step 4: Restore no-spaces mode for subsequent PID reads.
    await _cmd('ATS0');

    debugPrint('DTC raw response: $raw');
    final codes = _parseDtcs(raw);
    debugPrint('DTC parsed codes: $codes');
    return codes;
  }

  // Read a custom PID by 2-char hex code
  Future<String> readCustomPid(String pidHex) async {
    final r = await _cmd('01$pidHex');
    return _extractData(r);
  }

  String _extractData(String raw) {
    String clean = raw
        .replaceAll('>', '')
        .replaceAll(RegExp(r'\s'), '')
        .toUpperCase();

    // Strip Mode 01 response header: 41 + 1-byte PID echo (e.g. 410C, 4105)
    clean = clean.replaceAll(RegExp(r'^41[0-9A-F]{2}'), '');

    // Strip Mode 22 response header: 62 + 2-byte PID echo (e.g. 622113)
    // A and B in the formula refer to the DATA bytes — NOT the identifier bytes.
    // e.g. Powerstroke oil temp: 62 21 13 A B — A starts at byte 4, B at byte 5
    clean = clean.replaceAll(RegExp(r'^62[0-9A-F]{4}'), '');

    // Strip Mode 21 response header: 61 + 1-byte PID echo
    clean = clean.replaceAll(RegExp(r'^61[0-9A-F]{2}'), '');

    clean = clean.replaceAll(RegExp(r'[^0-9A-F]'), '');
    return clean;
  }

  /// Parse a Mode 22 extended PID response into named byte values.
  /// Returns {'A': int, 'B': int, 'C': int, ...} — header bytes already stripped.
  Map<String, int> extractMode22Bytes(String raw) {
    final hex = _extractData(raw);
    final result = <String, int>{};
    const labels = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H',
      'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P'];
    for (int i = 0; i + 1 < hex.length && i ~/ 2 < labels.length; i += 2) {
      result[labels[i ~/ 2]] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  List<String> _parseDtcs(String raw) {
    final codes = <String>[];
    try {
      final upper = raw.toUpperCase();

      // Guard: explicit no-data responses
      if (upper.contains('NO DATA') || upper.contains('UNABLE') ||
          upper.contains('ERROR') || raw.isEmpty) {
        return codes;
      }

      // Normalise: strip prompt chars and non-hex, collapse whitespace
      final stripped = upper
          .replaceAll(RegExp(r'[>\r\n]'), ' ')
          .replaceAll(RegExp(r'[^0-9A-F ]'), ' ')
          .trim();

      // Try SPACED format first: "43 01 33 00 00"
      // Adapter had ATS1 set — bytes arrive as space-separated tokens.
      final tokens = stripped
          .split(RegExp(r'\s+'))
          .where((t) => t.length == 2)   // keep only 2-char byte tokens
          .toList();

      int startIdx = tokens.indexOf('43');

      if (startIdx >= 0) {
        // ── Spaced path ──────────────────────────────────────────────────
        final data = tokens.sublist(startIdx + 1).toList();

        // Skip optional count byte (upper nibble > 3 → can't be DTC byte1)
        if (data.isNotEmpty) {
          final first = int.tryParse(data[0], radix: 16) ?? 0;
          if ((first >> 4) > 3) data.removeAt(0);
        }

        for (int i = 0; i + 1 < data.length; i += 2) {
          final b1 = int.tryParse(data[i],     radix: 16);
          final b2 = int.tryParse(data[i + 1], radix: 16);
          if (b1 == null || b2 == null) continue;
          if (b1 == 0 && b2 == 0) break;
          _decodeDtcWord(b1, b2, codes);
        }
      } else {
        // ── Spaceless path ───────────────────────────────────────────────
        // ATS0 was active or adapter ignored ATS1: response is a continuous
        // hex string like "430101330000" or "7E80643010133".
        // Find '43' followed by pairs of hex digits.
        final compact = stripped.replaceAll(' ', '');

        // Find the FIRST occurrence of '43' that is at an even byte boundary
        // relative to the start of the response (position % 2 == 0 after
        // stripping any leading CAN header bytes).
        // We scan looking for '43' where the preceding token boundaries
        // suggest it is a response byte, not data.
        int pos = 0;
        while (pos < compact.length - 1) {
          final idx = compact.indexOf('43', pos);
          if (idx < 0) break;

          // Only accept '43' at an even nibble boundary within the byte stream
          if (idx % 2 == 0) {
            // Skip any leading CAN/ISO header bytes (7E8, etc.) that may
            // precede the 43.  Headers are always > 0x3F so if bytes before
            // '43' have upper nibble > 3 they're headers — skip them.
            bool validStart = true;
            for (int b = 0; b < idx; b += 2) {
              if (b + 2 > idx) { validStart = false; break; }
              final hb = int.tryParse(compact.substring(b, b + 2), radix: 16) ?? 0;
              if ((hb >> 4) <= 3) { validStart = false; break; } // looks like DTC data, not header
            }

            final dataStart = idx + 2; // skip '43'
            if (dataStart < compact.length) {
              String dataHex = compact.substring(dataStart);

              // Skip count byte if upper nibble > 3
              if (dataHex.length >= 2) {
                final maybe = int.tryParse(dataHex.substring(0, 2), radix: 16) ?? 0;
                if ((maybe >> 4) > 3) dataHex = dataHex.substring(2);
              }

              for (int i = 0; i + 3 < dataHex.length; i += 4) {
                final b1 = int.tryParse(dataHex.substring(i,     i + 2), radix: 16);
                final b2 = int.tryParse(dataHex.substring(i + 2, i + 4), radix: 16);
                if (b1 == null || b2 == null) continue;
                if (b1 == 0 && b2 == 0) break;
                _decodeDtcWord(b1, b2, codes);
              }

              if (codes.isNotEmpty) break; // found valid DTCs — stop searching
            }
          }
          pos = idx + 2;
        }
      }
    } catch (e) {
      debugPrint('DTC parse error: $e');
    }
    return codes;
  }

  /// Decodes a 16-bit SAE J2012 DTC word into a code string and adds to list.
  /// b1/b2 are the two raw bytes.  Skips 0x0000 padding and deduplicates.
  static void _decodeDtcWord(int b1, int b2, List<String> codes) {
    final prefix  = ['P', 'C', 'B', 'U'][(b1 >> 6) & 0x03];
    final digit2  = (b1 >> 4) & 0x03;
    final digit3  = (b1 & 0x0F).toRadixString(16).toUpperCase();
    final digit45 = b2.toRadixString(16).toUpperCase().padLeft(2, '0');
    final code    = '$prefix$digit2$digit3$digit45';
    if (code.length == 5 && code != 'P0000' && !codes.contains(code)) {
      codes.add(code);
    }
  }

  // ── DRAIN ADAPTER BUFFER ─────────────────────────────────
  /// Clears any queued BLE responses before sending a fresh command.
  /// Critical for Mode 22 — prevents bleed from previous replies.
  Future<void> drainAdapter() async {
    // Send a blank CR to the adapter and wait for the '>' prompt.
    // This actually consumes any bytes still in the hardware UART/BLE stream
    // rather than just clearing the in-memory buffer.
    _responseBuffer.clear();
    try {
      final bytes = utf8.encode('\r');
      if (_isClassic) {
        _classicConnection?.output.add(bytes);
        await _classicConnection?.output.allSent;
      } else if (_writeChar != null) {
        if (_writeChar!.properties.writeWithoutResponse) {
          await _writeChar!.write(bytes, withoutResponse: true);
        } else {
          await _writeChar!.write(bytes);
        }
      }
    } catch (_) {}
    // Wait up to 600ms for the '>' prompt, then clear whatever arrived
    for (int i = 0; i < 12; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
      final r = utf8.decode(_responseBuffer, allowMalformed: true);
      if (r.contains('>')) break;
    }
    _responseBuffer.clear();
  }

  // ── MODE 22 SINGLE PID READ ───────────────────────────────
  /// Reads one Mode 22 PID.  [pidHex] is 4 chars e.g. '1310'.
  /// [txAddr] / [rxAddr] default to ECM (7E0/7E8); pass TCM for trans temp.
  /// Returns raw A/B/C bytes or empty map on failure.
  Future<Map<String, int>> readMode22Pid(
      String pidHex, {
        String txAddr = '7E0',
        int numBytes = 2,
      }) async {
    final ph = pidHex.substring(0, 2).toUpperCase();
    final pl = pidHex.substring(2, 4).toUpperCase();
    try {
      await drainAdapter();
      await _cmd('ATSH $txAddr');
      await drainAdapter();
      final raw = await _cmd('22$ph$pl');
      // Blob-search for "62{PH}{PL}" marker
      final blob = raw.replaceAll(RegExp(r'[\s\r\n>]'), '').toUpperCase();
      final marker = '62$ph$pl';
      final idx = blob.indexOf(marker);
      if (idx < 0) return {};
      final dataHex = blob.substring(idx + marker.length);
      if (dataHex.length < numBytes * 2) return {};
      final result = <String, int>{};
      const labels = ['A','B','C','D','E','F'];
      for (int i = 0; i < numBytes && i < labels.length; i++) {
        result[labels[i]] =
            int.parse(dataHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  // ── POWERSTROKE MODE 22 FULL SWEEP ────────────────────────
  /// Reads all 12 critical Powerstroke PIDs and returns formatted strings.
  /// Keys are prefixed with 'ps_' so they can be identified in rawObd.
  // ── POWERSTROKE GENERATION DETECTOR ─────────────────────
  /// Returns 73, 60, 64, or 67 based on engine string from NHTSA decode.
  /// Used to pick the correct Mode 22 PID set.
  static int detectPowerstrokeGen(String engineStr) {
    final e = engineStr.toLowerCase();
    if (e.contains('7.3') || e.contains('7.3l')) return 73;
    if (e.contains('6.0') || e.contains('6.0l')) return 60;
    if (e.contains('6.4') || e.contains('6.4l')) return 64;
    if (e.contains('6.7') || e.contains('6.7l')) return 67;
    return 60; // default to 6.0L if unknown diesel
  }

  // ── POWERSTROKE DISPATCHER ────────────────────────────────
  /// Calls the correct generation reader based on engine string.
  Future<Map<String, String>> readPowerstrokePids({int gen = 60}) async {
    switch (gen) {
      case 73: return _readPowerstroke73();
      case 64: return _readPowerstroke64();
      case 67: return _readPowerstroke67();
      case 60:
      default: return _readPowerstroke60();
    }
  }

  // ── 6.0L POWERSTROKE (2003–2007) ─────────────────────────
  /// Confirmed working PIDs on 2006 F-250 6.0L with Veepeak BLE dongle.
  /// Extra EGR cooler temps added from reference data (field-validate first use).
  Future<Map<String, String>> _readPowerstroke60() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96');
      await _cmd('ATH0');
      await _cmd('ATS0');

      // ── CONFIRMED WORKING (field-validated) ──
      var b = await readMode22Pid('1310');
      if (b.isNotEmpty) {
        final f = (((b['A']! * 256 + b['B']!) / 100 - 40) * 9 / 5 + 32);
        out['ps_oil_temp'] = '${f.toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('1446');
      if (b.isNotEmpty) {
        out['ps_icp_psi'] = '${((b['A']! * 256 + b['B']!) * 0.57).toStringAsFixed(0)} psi';
      }
      b = await readMode22Pid('1445');
      if (b.isNotEmpty) {
        out['ps_map_psi'] = '${((b['A']! * 256 + b['B']!) * 0.03625).toStringAsFixed(2)} psi';
      }
      b = await readMode22Pid('1440');
      if (b.isNotEmpty) {
        out['ps_boost_psi'] = '${((b['A']! * 256 + b['B']!) * 0.03625).toStringAsFixed(2)} psi';
      }
      b = await readMode22Pid('09CF');
      if (b.isNotEmpty) {
        out['ps_ficm_logic_v'] = '${((b['A']! * 256 + b['B']!) * 100 / 256 / 100).toStringAsFixed(2)}V';
      }
      b = await readMode22Pid('09D0');
      if (b.isNotEmpty) {
        out['ps_ficm_main_v'] = '${((b['A']! * 256 + b['B']!) * 100 / 256 / 100).toStringAsFixed(2)}V';
      }
      b = await readMode22Pid('1434', numBytes: 1);
      if (b.isNotEmpty) {
        out['ps_ipr_pct'] = '${((b['A']! * 13.53) / 35).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('1624');
      if (b.isNotEmpty) {
        out['ps_cht_f'] = '${((b['A']! * 256 + b['B']!) * 1.999 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('1412');
      if (b.isNotEmpty) {
        out['ps_fuel_mg'] = '${((b['A']! * 256 + b['B']!) * 0.0625).toStringAsFixed(2)} mg/stk';
      }
      b = await readMode22Pid('096D');
      if (b.isNotEmpty) {
        out['ps_vgt_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 32767).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('09CC');
      if (b.isNotEmpty) {
        out['ps_inj_timing'] = '${((b['A']! * 256 + b['B']!) * 10 / 64 / 10).toStringAsFixed(2)}°';
      }
      b = await readMode22Pid('1674', txAddr: '7E1');
      if (b.isNotEmpty) {
        out['ps_trans_temp'] = '${((b['A']! * 256 + b['B']!) / 8).toStringAsFixed(1)}°F';
      }

      // ── CRITICAL 6.0L ADDITIONS — EGR cooler health ──
      // (field-validate on first use — PIDs from Ford reference data)
      b = await readMode22Pid('020D'); // EGR Cooler Inlet Temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_egr_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('020E'); // EGR Cooler Outlet Temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_egr_out_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0216'); // Engine Oil Pressure
      if (b.isNotEmpty) {
        final kpa = (b['A']! * 256 + b['B']!) * 0.58;
        final psi = kpa * 0.1450377;
        out['ps_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }

    } catch (e) {
      debugPrint('6.0L Powerstroke read error: $e');
    } finally {
      await _cmd('ATSH 7DF');
      await _cmd('ATST00');
    }
    return out;
  }

  // ── 7.3L POWERSTROKE (1994–2003) ─────────────────────────
  /// HEUI system — ICP/IPR are the critical sensors.
  /// Field validation required — not tested on hardware yet.
  Future<Map<String, String>> _readPowerstroke73() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96');
      await _cmd('ATH0');
      await _cmd('ATS0');

      var b = await readMode22Pid('0102'); // ICP pressure
      if (b.isNotEmpty) {
        out['ps_icp_psi'] = '${((b['A']! * 256 + b['B']!) * 0.082).toStringAsFixed(0)} psi';
      }
      b = await readMode22Pid('0103'); // ICP target
      if (b.isNotEmpty) {
        out['ps_icp_target'] = '${((b['A']! * 256 + b['B']!) * 0.082).toStringAsFixed(0)} psi';
      }
      b = await readMode22Pid('0104'); // IPR duty
      if (b.isNotEmpty) {
        out['ps_ipr_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0109'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_oil_temp'] = '${(c * 9 / 5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('010A'); // Fuel temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_fuel_temp_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0116'); // Boost
      if (b.isNotEmpty) {
        final kpa = (b['A']! * 256 + b['B']!) * 0.01;
        out['ps_boost_psi'] = '${(kpa * 0.1450377).toStringAsFixed(2)} psi';
      }
      b = await readMode22Pid('0113'); // Glow plug relay
      if (b.isNotEmpty) {
        out['ps_glow_relay'] = (b['A']! & 1) == 1 ? 'ON' : 'OFF';
      }
      b = await readMode22Pid('0125'); // HPOP duty
      if (b.isNotEmpty) {
        out['ps_hpop_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0111'); // Injection timing desired
      if (b.isNotEmpty) {
        out['ps_inj_timing'] = '${((b['A']! * 256 + b['B']!) * 0.5 - 64).toStringAsFixed(2)}°';
      }
      b = await readMode22Pid('0136'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_trans_temp'] = '${(c * 9 / 5 + 32).toStringAsFixed(1)}°F';
      }

    } catch (e) {
      debugPrint('7.3L Powerstroke read error: $e');
    } finally {
      await _cmd('ATSH 7DF');
      await _cmd('ATST00');
    }
    return out;
  }

  // ── 6.4L POWERSTROKE (2008–2010) ─────────────────────────
  /// Dual series-sequential turbo + common rail CP4 + DPF.
  /// Field validation required — not tested on hardware yet.
  Future<Map<String, String>> _readPowerstroke64() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96');
      await _cmd('ATH0');
      await _cmd('ATS0');

      var b = await readMode22Pid('0303'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_oil_temp'] = '${(c * 9 / 5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('030A'); // Boost stage 1 (low turbo)
      if (b.isNotEmpty) {
        final kpa = (b['A']! * 256 + b['B']!) * 0.01;
        out['ps_boost1_psi'] = '${(kpa * 0.1450377).toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('030B'); // Boost stage 2 (high turbo)
      if (b.isNotEmpty) {
        final kpa = (b['A']! * 256 + b['B']!) * 0.01;
        out['ps_boost2_psi'] = '${(kpa * 0.1450377).toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('031E'); // Rail pressure actual
      if (b.isNotEmpty) {
        final kpa = (b['A']! * 256 + b['B']!) * 100.0;
        out['ps_rail_kpa'] = '${(kpa / 1000).toStringAsFixed(0)} MPa';
      }
      b = await readMode22Pid('031A'); // EGR cooler inlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_egr_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('031B'); // EGR cooler outlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_egr_out_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0334'); // DPF soot loading
      if (b.isNotEmpty) {
        out['ps_dpf_soot'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0335'); // DPF differential pressure
      if (b.isNotEmpty) {
        out['ps_dpf_dp'] = '${((b['A']! * 256 + b['B']!) * 0.01).toStringAsFixed(2)} kPa';
      }
      b = await readMode22Pid('0336'); // DPF inlet temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_dpf_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('034B'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_trans_temp'] = '${(c * 9 / 5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0348'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['ps_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('033E'); // Fuel dilution in oil
      if (b.isNotEmpty) {
        out['ps_fuel_dilution'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }

    } catch (e) {
      debugPrint('6.4L Powerstroke read error: $e');
    } finally {
      await _cmd('ATSH 7DF');
      await _cmd('ATST00');
    }
    return out;
  }

  // ── 6.7L POWERSTROKE (2011+) ─────────────────────────────
  /// CP4.2 common rail + single VGT + full DEF/SCR aftertreatment.
  /// Field validation required — not tested on hardware yet.
  Future<Map<String, String>> _readPowerstroke67() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96');
      await _cmd('ATH0');
      await _cmd('ATS0');

      var b = await readMode22Pid('0403'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_oil_temp'] = '${(c * 9 / 5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('040B'); // Boost actual
      if (b.isNotEmpty) {
        final kpa = (b['A']! * 256 + b['B']!) * 0.01;
        out['ps_boost_psi'] = '${(kpa * 0.1450377).toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('040D'); // VGT actual
      if (b.isNotEmpty) {
        out['ps_vgt_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0415'); // Rail pressure actual
      if (b.isNotEmpty) {
        final kpa = (b['A']! * 256 + b['B']!) * 100.0;
        out['ps_rail_kpa'] = '${(kpa / 1000).toStringAsFixed(0)} MPa';
      }
      b = await readMode22Pid('0434'); // EGR cooler inlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_egr_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0435'); // EGR cooler outlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_egr_out_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('043B'); // DPF soot
      if (b.isNotEmpty) {
        out['ps_dpf_soot'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('043C'); // DPF diff pressure
      if (b.isNotEmpty) {
        out['ps_dpf_dp'] = '${((b['A']! * 256 + b['B']!) * 0.01).toStringAsFixed(2)} kPa';
      }
      b = await readMode22Pid('043D'); // DPF inlet temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_dpf_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('044C', numBytes: 1); // DEF level
      if (b.isNotEmpty) {
        out['ps_def_level'] = '${(b['A']! * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('044D', numBytes: 1); // DEF quality
      if (b.isNotEmpty) {
        out['ps_def_quality'] = '${(b['A']! * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0449'); // NOx upstream
      if (b.isNotEmpty) {
        out['ps_nox_up'] = '${((b['A']! * 256 + b['B']!) * 0.05).toStringAsFixed(0)} ppm';
      }
      b = await readMode22Pid('044A'); // NOx downstream
      if (b.isNotEmpty) {
        out['ps_nox_dn'] = '${((b['A']! * 256 + b['B']!) * 0.05).toStringAsFixed(0)} ppm';
      }
      b = await readMode22Pid('0458'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['ps_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('0405'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['ps_trans_temp'] = '${(c * 9 / 5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('045A'); // Oil life
      if (b.isNotEmpty) {
        out['ps_oil_life'] = '${b['A']!}%';
      }
      b = await readMode22Pid('0484'); // CP4 wear index
      if (b.isNotEmpty) {
        out['ps_cp4_wear'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }

    } catch (e) {
      debugPrint('6.7L Powerstroke read error: $e');
    } finally {
      await _cmd('ATSH 7DF');
      await _cmd('ATST00');
    }
    return out;
  }

  // ── MODE 01 EXTENDED PID (blob-search parser) ────────────
  /// Reads a standard Mode 01 PID that isn't covered by the named methods.
  /// Uses the same blob-search approach as Mode 22 for reliability.
  Future<Map<String, int>> readMode01ExtPid(
      String pidHex, {
        int numBytes = 2,
      }) async {
    final ph = pidHex.toUpperCase();
    try {
      await drainAdapter();
      final raw = await _cmd('01$ph');
      final blob = raw.replaceAll(RegExp(r'[\s\r\n>]'), '').toUpperCase();
      final marker = '41$ph';
      final idx = blob.indexOf(marker);
      if (idx < 0) return {};
      final dataHex = blob.substring(idx + marker.length);
      if (dataHex.length < numBytes * 2) return {};
      final result = <String, int>{};
      const labels = ['A', 'B', 'C', 'D'];
      for (int i = 0; i < numBytes && i < labels.length; i++) {
        result[labels[i]] =
            int.parse(dataHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  // ── MODE 21 SINGLE PID READ (Toyota enhanced) ────────────
  /// Toyota Mode 21 enhanced PIDs. PID is 1 byte, response header is 61 XX.
  Future<Map<String, int>> readMode21Pid(
      String pidHex, {
        String txAddr = '7E0',
        int numBytes = 2,
      }) async {
    final ph = pidHex.toUpperCase();
    try {
      await drainAdapter();
      await _cmd('ATSH $txAddr');
      await drainAdapter();
      final raw = await _cmd('21$ph');
      final blob = raw.replaceAll(RegExp(r'[\s\r\n>]'), '').toUpperCase();
      final marker = '61$ph';
      final idx = blob.indexOf(marker);
      if (idx < 0) return {};
      final dataHex = blob.substring(idx + marker.length);
      if (dataHex.length < numBytes * 2) return {};
      final result = <String, int>{};
      const labels = ['A', 'B', 'C', 'D', 'E', 'F'];
      for (int i = 0; i < numBytes && i < labels.length; i++) {
        result[labels[i]] =
            int.parse(dataHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  // ── TOYOTA MODE 21 + MODE 01 EXTENDED SWEEP ──────────────
  /// Reads ~18 high-value Toyota PIDs silently in the background.
  /// Selected for 2010 Tacoma 4.0L V6 (1GR-FE) — skips hybrid/CVT/diesel.
  /// Keys prefixed with 'to_' so AI and Stats can identify them.
  Future<Map<String, String>> readToyotaPids() async {
    final out = <String, String>{};
    try {
      await _cmd('ATH0');
      await _cmd('ATS0');

      // ── Mode 01 Extended — universal PIDs not in standard scan ──

      // Engine Oil Temperature (01 5C)
      var b = await readMode01ExtPid('5C', numBytes: 1);
      if (b.isNotEmpty) {
        final tempC = (b['A']! - 40).toDouble();
        final tempF = tempC * 9 / 5 + 32;
        out['to_oil_temp'] = '${tempF.toStringAsFixed(1)}°F';
      }

      // Intake Air Temperature (01 0F)
      b = await readMode01ExtPid('0F', numBytes: 1);
      if (b.isNotEmpty) {
        final tempC = (b['A']! - 40).toDouble();
        out['to_iat'] = '${tempC.toStringAsFixed(1)}°C';
      }

      // Mass Air Flow (01 10)
      b = await readMode01ExtPid('10', numBytes: 2);
      if (b.isNotEmpty) {
        final maf = (b['A']! * 256 + b['B']!) / 100.0;
        out['to_maf'] = '${maf.toStringAsFixed(2)} g/s';
      }

      // Short Term Fuel Trim Bank 1 (01 06)
      b = await readMode01ExtPid('06', numBytes: 1);
      if (b.isNotEmpty) {
        final pct = (b['A']! - 128) * 100 / 128.0;
        out['to_stft_b1'] = '${pct.toStringAsFixed(1)}%';
      }

      // Long Term Fuel Trim Bank 1 (01 07)
      b = await readMode01ExtPid('07', numBytes: 1);
      if (b.isNotEmpty) {
        final pct = (b['A']! - 128) * 100 / 128.0;
        out['to_ltft_b1'] = '${pct.toStringAsFixed(1)}%';
      }

      // Short Term Fuel Trim Bank 2 (01 08)
      b = await readMode01ExtPid('08', numBytes: 1);
      if (b.isNotEmpty) {
        final pct = (b['A']! - 128) * 100 / 128.0;
        out['to_stft_b2'] = '${pct.toStringAsFixed(1)}%';
      }

      // Long Term Fuel Trim Bank 2 (01 09)
      b = await readMode01ExtPid('09', numBytes: 1);
      if (b.isNotEmpty) {
        final pct = (b['A']! - 128) * 100 / 128.0;
        out['to_ltft_b2'] = '${pct.toStringAsFixed(1)}%';
      }

      // Catalyst Temperature Bank 1 Sensor 1 (01 3C)
      b = await readMode01ExtPid('3C', numBytes: 2);
      if (b.isNotEmpty) {
        final tempC = (b['A']! * 256 + b['B']!) / 10.0 - 40;
        out['to_cat_temp_b1'] = '${tempC.toStringAsFixed(0)}°C';
      }

      // Catalyst Temperature Bank 2 Sensor 1 (01 3D)
      b = await readMode01ExtPid('3D', numBytes: 2);
      if (b.isNotEmpty) {
        final tempC = (b['A']! * 256 + b['B']!) / 10.0 - 40;
        out['to_cat_temp_b2'] = '${tempC.toStringAsFixed(0)}°C';
      }

      // ── Mode 21 Toyota Enhanced PIDs ──

      // VVT-i Intake Cam Timing Bank 1 (21 20)
      // Toyota returns 1 data byte for cam timing: A*0.5-64 → valid range -64 to +63.5°
      b = await readMode21Pid('20', numBytes: 1);
      if (b.isNotEmpty) {
        final deg = b['A']! * 0.5 - 64;
        if (deg >= -64 && deg <= 64) {
          out['to_vvti_b1'] = '${deg.toStringAsFixed(1)}° CA';
        }
      }

      // VVT-i Intake Cam Timing Bank 2 (21 21)
      b = await readMode21Pid('21', numBytes: 1);
      if (b.isNotEmpty) {
        final deg = b['A']! * 0.5 - 64;
        if (deg >= -64 && deg <= 64) {
          out['to_vvti_b2'] = '${deg.toStringAsFixed(1)}° CA';
        }
      }

      // O2 Sensor B1S1 (21 11) — upstream
      b = await readMode21Pid('11');
      if (b.isNotEmpty) {
        final v = (b['A']! * 256 + b['B']!) * 0.00122;
        out['to_o2_b1s1'] = '${v.toStringAsFixed(3)}V';
      }

      // O2 Sensor B1S2 (21 12) — downstream (cat monitor)
      b = await readMode21Pid('12');
      if (b.isNotEmpty) {
        final v = (b['A']! * 256 + b['B']!) * 0.00122;
        out['to_o2_b1s2'] = '${v.toStringAsFixed(3)}V';
      }

      // O2 Sensor B2S1 (21 13) — upstream
      b = await readMode21Pid('13');
      if (b.isNotEmpty) {
        final v = (b['A']! * 256 + b['B']!) * 0.00122;
        out['to_o2_b2s1'] = '${v.toStringAsFixed(3)}V';
      }

      // O2 Sensor B2S2 (21 14) — downstream
      b = await readMode21Pid('14');
      if (b.isNotEmpty) {
        final v = (b['A']! * 256 + b['B']!) * 0.00122;
        out['to_o2_b2s2'] = '${v.toStringAsFixed(3)}V';
      }

      // Knock Correction Bank 1 (21 32)
      // Toyota knock correction is 1 byte: A*0.5 → 0-20° retard range
      b = await readMode21Pid('32', numBytes: 1);
      if (b.isNotEmpty) {
        final deg = b['A']! * 0.5;
        if (deg >= 0 && deg <= 40) {
          out['to_knock_b1'] = '${deg.toStringAsFixed(1)}° CA';
        }
      }

      // Knock Correction Bank 2 (21 33)
      b = await readMode21Pid('33', numBytes: 1);
      if (b.isNotEmpty) {
        final deg = b['A']! * 0.5;
        if (deg >= 0 && deg <= 40) {
          out['to_knock_b2'] = '${deg.toStringAsFixed(1)}° CA';
        }
      }

      // Transmission Oil Temperature (21 62)
      b = await readMode21Pid('62');
      if (b.isNotEmpty) {
        final tempC = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        final tempF = tempC * 9 / 5 + 32;
        out['to_trans_temp'] = '${tempF.toStringAsFixed(1)}°F';
      }

      // 4WD Status (21 69) — 1 byte bit-encoded
      b = await readMode21Pid('69', numBytes: 1);
      if (b.isNotEmpty) {
        final v = b['A']!;
        // Common Toyota encoding: 0=2H, 1=4H, 2=4L, bit 0=4WD active
        final mode = v == 0
            ? '2WD'
            : v == 1
            ? '4H'
            : v == 2
            ? '4L'
            : '0x${v.toRadixString(16).toUpperCase()}';
        out['to_4wd'] = mode;
      }

      // Fuel Economy Instantaneous (21 60)
      b = await readMode21Pid('60');
      if (b.isNotEmpty) {
        final kmL = (b['A']! * 256 + b['B']!) * 0.1;
        final mpg = kmL * 2.352; // km/L → US MPG
        out['to_fuel_econ'] = '${mpg.toStringAsFixed(1)} mpg';
      }

    } catch (e) {
      debugPrint('Toyota PID read error: $e');
    } finally {
      // Restore standard ECM header
      await _cmd('ATSH 7DF');
    }
    return out;
  }


  // ── GM GENERATION DETECTOR ───────────────────────────────
  /// Returns a generation string based on make/fuel/year/engine.
  /// 'gas' = GM gas (LS/LT/EcoTec3)
  /// 'lb7' = 2001-2004 Duramax LB7
  /// 'lly_lbz' = 2004.5-2007 Duramax LLY/LBZ
  /// 'lmm' = 2007.5-2010 Duramax LMM
  /// 'lml' = 2011-2016 Duramax LML
  /// 'l5p' = 2017+ Duramax L5P
  static String detectGmGen({
    required String fuelType,
    required String engine,
    required String year,
  }) {
    final fuel = fuelType.toLowerCase();
    final eng  = engine.toLowerCase();
    if (!fuel.contains('diesel') && !eng.contains('diesel')) return 'gas';
    // Duramax generation by year
    final y = int.tryParse(year) ?? 0;
    if (y >= 2017) return 'l5p';
    if (y >= 2011) return 'lml';
    if (y == 2007 || y == 2008 || y == 2009 || y == 2010) return 'lmm';
    if (y == 2006 || y == 2005 || y == 2004) return 'lly_lbz';
    if (y >= 2001 && y <= 2003) return 'lb7';
    return 'lml'; // default to LML if year unknown
  }

  // ── GM DISPATCHER ────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════════════════
  //  UNIVERSAL MANUFACTURER PID READER
  //  Replaces all per-vehicle hardcoded fetch functions.
  //  Reads every PID from PidRegistry for the given vehicleMake key,
  //  uses the byte count inferred from the formula, applies the formula,
  //  and sanity-checks the result against min/max.
  //  Adding a new vehicle = just add CSV data. Zero new code needed.
  // ══════════════════════════════════════════════════════════════════════════
  Future<Map<String, String>> readManufacturerPids(String vehicleMake) async {
    final out = <String, String>{};
    final makeKey = vehicleMake.toUpperCase();

    // Get all PIDs for this vehicle make from registry
    final pids = PidRegistry.all
        .where((p) => p.vehicleMake?.toUpperCase() == makeKey)
        .toList();

    if (pids.isEmpty) {
      debugPrint('No PIDs found for make: $makeKey');
      return out;
    }

    debugPrint('Universal reader: ${pids.length} PIDs for $makeKey');

    try {
      await _cmd('ATH0');
      await _cmd('ATS0');

      for (final pid in pids) {
        try {
          final numBytes = pid.effectiveBytes;
          final bytes = await readMode22Pid(pid.pid, numBytes: numBytes);
          if (bytes.isEmpty) continue;

          final value = pid.evaluate(bytes);

          if (value != null) {
            // Sanity check — skip values wildly outside expected range
            // (catches stale buffer bytes that decode to garbage numbers)
            final range = pid.maxValue - pid.minValue;
            final slack = range > 0 ? range * 0.25 : 50;
            if (value < pid.minValue - slack || value > pid.maxValue + slack) {
              debugPrint('Out of range skip: ${pid.name} = $value '
                  '(expected ${pid.minValue}–${pid.maxValue})');
              continue;
            }

            // Format with appropriate precision
            final formatted = _formatPidValue(value, pid.unit);
            final key = '${makeKey.toLowerCase()}_${pid.pid.toLowerCase()}';
            out[key] = formatted;
          } else {
            // Non-numeric / bit-encoded — store raw byte A as status
            final A = bytes['A'] ?? 0;
            final key = '${makeKey.toLowerCase()}_${pid.pid.toLowerCase()}';
            out[key] = _decodeBitStatus(A, pid.formula);
          }
        } catch (e) {
          debugPrint('PID read error for ${pid.pid}: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('readManufacturerPids error: $e');
    } finally {
      await _cmd('ATSH 7DF'); // restore broadcast header
    }

    debugPrint('Universal reader: got ${out.length}/${pids.length} values for $makeKey');
    return out;
  }

  /// Formats a numeric PID value with unit-appropriate decimal places.
  static String _formatPidValue(double value, String unit) {
    final u = unit.toLowerCase();
    // Whole number units
    if (u == 'rpm' || u == 'km' || u == 'km/h' || u == 'count' ||
        u == 'gear' || u == 'level' || u == 'cylinders' || u == 'min' ||
        u == 's' || u == 'days') {
      return '${value.round()} $unit';
    }
    // Percent and temperature — 1 decimal
    if (u == '%' || u.contains('°')) {
      return '${value.toStringAsFixed(1)} $unit';
    }
    // Pressure and voltage — 1 decimal
    if (u == 'kpa' || u == 'bar' || u == 'v' || u == 'a' || u == 'psi') {
      return '${value.toStringAsFixed(1)} $unit';
    }
    // High-precision (lambda, ms, mm, ratio)
    if (u == 'lambda' || u == 'ms' || u == 'mm' || u == 'ratio') {
      return '${value.toStringAsFixed(3)} $unit';
    }
    // Default: 2 decimal places
    return '${value.toStringAsFixed(2)} $unit';
  }

  /// Decodes simple bit-encoded status bytes to human-readable strings.
  static String _decodeBitStatus(int byte, String formula) {
    final fl = formula.toLowerCase();
    if (fl.contains('bit 0')) {
      final label = formula.contains(':') ? formula.split(':').last.trim() : '';
      return (byte & 0x01) == 1 ? label.isNotEmpty ? label : 'Active' : 'Off';
    }
    return '0x${byte.toRadixString(16).toUpperCase().padLeft(2, "0")}';
  }

  Future<Map<String, String>> readGmPids({String gen = 'gas'}) async {
    switch (gen) {
      case 'lb7':    return _readGmLb7();
      case 'lly_lbz': return _readGmLlyLbz();
      case 'lmm':    return _readGmLmm();
      case 'lml':    return _readGmLml();
      case 'l5p':    return _readGmL5p();
      case 'gas':
      default:       return _readGmGas();
    }
  }

  // ── GM GAS (LS/LT/EcoTec3) ───────────────────────────────
  /// Mode 22 enhanced PIDs for GM gasoline engines.
  /// Covers VVT cam timing, knock retard, fuel trims, AFM status,
  /// oil life, trans temp. Field validation required.
  Future<Map<String, String>> _readGmGas() async {
    final out = <String, String>{};
    try {
      await _cmd('ATH0');
      await _cmd('ATS0');

      var b = await readMode22Pid('0131'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_oil_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0132'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['gm_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('0133', numBytes: 1); // Oil life
      if (b.isNotEmpty) {
        out['gm_oil_life'] = '${b['A']!}%';
      }
      b = await readMode22Pid('010D'); // O2 B1S1 upstream
      if (b.isNotEmpty) {
        out['gm_o2_b1s1'] = '${((b['A']! * 256 + b['B']!) * 0.00122).toStringAsFixed(3)}V';
      }
      b = await readMode22Pid('010E'); // O2 B1S2 downstream
      if (b.isNotEmpty) {
        out['gm_o2_b1s2'] = '${((b['A']! * 256 + b['B']!) * 0.00122).toStringAsFixed(3)}V';
      }
      b = await readMode22Pid('011F'); // Knock retard B1
      if (b.isNotEmpty) {
        out['gm_knock_b1'] = '${((b['A']! * 256 + b['B']!) * 0.5).toStringAsFixed(1)}°';
      }
      b = await readMode22Pid('0120'); // Knock retard B2
      if (b.isNotEmpty) {
        out['gm_knock_b2'] = '${((b['A']! * 256 + b['B']!) * 0.5).toStringAsFixed(1)}°';
      }
      b = await readMode22Pid('0123'); // VVT intake B1 actual
      if (b.isNotEmpty) {
        out['gm_vvt_in_b1'] = '${((b['A']! * 256 + b['B']!) * 0.5 - 64).toStringAsFixed(1)}° CA';
      }
      b = await readMode22Pid('0125'); // VVT intake B2 actual
      if (b.isNotEmpty) {
        out['gm_vvt_in_b2'] = '${((b['A']! * 256 + b['B']!) * 0.5 - 64).toStringAsFixed(1)}° CA';
      }
      b = await readMode22Pid('0154', numBytes: 1); // AFM status
      if (b.isNotEmpty) {
        out['gm_afm_status'] = b['A']! == 0 ? 'All Cyl' : 'AFM Active';
      }
      b = await readMode22Pid('015E'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_trans_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('015A'); // Fuel economy instantaneous
      if (b.isNotEmpty) {
        out['gm_fuel_econ'] = '${((b['A']! * 256 + b['B']!) * 0.1).toStringAsFixed(1)} mpg';
      }

    } catch (e) {
      debugPrint('GM gas PID read error: $e');
    } finally {
      await _cmd('ATSH 7DF');
    }
    return out;
  }

  // ── DURAMAX LB7 (2001–2004) ──────────────────────────────
  /// Bosch CP3 common rail, no DPF/DEF. Injector failures are #1 issue.
  Future<Map<String, String>> _readGmLb7() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96'); await _cmd('ATH0'); await _cmd('ATS0');

      var b = await readMode22Pid('0503'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_oil_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('050F'); // Rail pressure actual
      if (b.isNotEmpty) {
        final mpa = (b['A']! * 256 + b['B']!) * 100.0 / 1000000;
        out['gm_rail_mpa'] = '${mpa.toStringAsFixed(0)} MPa';
      }
      b = await readMode22Pid('050A'); // Boost actual
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.01 * 0.1450377;
        out['gm_boost_psi'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('050C'); // VGT actual
      if (b.isNotEmpty) {
        out['gm_vgt_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0523'); // EGR valve pos
      if (b.isNotEmpty) {
        out['gm_egr_pos'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0520'); // Glow plug relay
      if (b.isNotEmpty) {
        out['gm_glow_relay'] = (b['A']! & 1) == 1 ? 'ON' : 'OFF';
      }
      b = await readMode22Pid('052A'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['gm_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('052B', numBytes: 1); // Oil life
      if (b.isNotEmpty) {
        out['gm_oil_life'] = '${b['A']!}%';
      }
      b = await readMode22Pid('0532'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_trans_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0513'); // Injection timing desired
      if (b.isNotEmpty) {
        out['gm_inj_timing'] = '${((b['A']! * 256 + b['B']!) * 0.5 - 64).toStringAsFixed(2)}°';
      }
      b = await readMode22Pid('0527'); // Fuel delivery pressure
      if (b.isNotEmpty) {
        out['gm_fuel_press'] = '${((b['A']! * 256 + b['B']!) * 0.1).toStringAsFixed(0)} kPa';
      }
      b = await readMode22Pid('0529', numBytes: 1); // Water in fuel
      if (b.isNotEmpty) {
        out['gm_water_fuel'] = (b['A']! & 1) == 1 ? 'DETECTED ⚠️' : 'OK';
      }

    } catch (e) {
      debugPrint('Duramax LB7 read error: $e');
    } finally {
      await _cmd('ATSH 7DF'); await _cmd('ATST00');
    }
    return out;
  }

  // ── DURAMAX LLY / LBZ (2004.5–2007) ─────────────────────
  /// Added EGR cooler — early cooler failures common on LLY.
  Future<Map<String, String>> _readGmLlyLbz() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96'); await _cmd('ATH0'); await _cmd('ATS0');

      var b = await readMode22Pid('0604'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_oil_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0613'); // Rail pressure actual
      if (b.isNotEmpty) {
        final mpa = (b['A']! * 256 + b['B']!) * 100.0 / 1000000;
        out['gm_rail_mpa'] = '${mpa.toStringAsFixed(0)} MPa';
      }
      b = await readMode22Pid('060B'); // Boost actual
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.01 * 0.1450377;
        out['gm_boost_psi'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('060D'); // VGT actual
      if (b.isNotEmpty) {
        out['gm_vgt_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('062B'); // EGR cooler inlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('062C'); // EGR cooler outlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_out_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0625'); // Glow plug relay
      if (b.isNotEmpty) {
        out['gm_glow_relay'] = (b['A']! & 1) == 1 ? 'ON' : 'OFF';
      }
      b = await readMode22Pid('0632'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['gm_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('0633', numBytes: 1); // Oil life
      if (b.isNotEmpty) {
        out['gm_oil_life'] = '${b['A']!}%';
      }
      b = await readMode22Pid('063B'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_trans_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0617'); // Injection timing desired
      if (b.isNotEmpty) {
        out['gm_inj_timing'] = '${((b['A']! * 256 + b['B']!) * 0.5 - 64).toStringAsFixed(2)}°';
      }
      b = await readMode22Pid('0631', numBytes: 1); // Water in fuel
      if (b.isNotEmpty) {
        out['gm_water_fuel'] = (b['A']! & 1) == 1 ? 'DETECTED ⚠️' : 'OK';
      }

    } catch (e) {
      debugPrint('Duramax LLY/LBZ read error: $e');
    } finally {
      await _cmd('ATSH 7DF'); await _cmd('ATST00');
    }
    return out;
  }

  // ── DURAMAX LMM (2007.5–2010) ────────────────────────────
  /// First Duramax with DPF. DPF soot loading critical.
  Future<Map<String, String>> _readGmLmm() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96'); await _cmd('ATH0'); await _cmd('ATS0');

      var b = await readMode22Pid('0704'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_oil_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0711'); // Rail pressure actual
      if (b.isNotEmpty) {
        final mpa = (b['A']! * 256 + b['B']!) * 100.0 / 1000000;
        out['gm_rail_mpa'] = '${mpa.toStringAsFixed(0)} MPa';
      }
      b = await readMode22Pid('070B'); // Boost actual
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.01 * 0.1450377;
        out['gm_boost_psi'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('070D'); // VGT actual
      if (b.isNotEmpty) {
        out['gm_vgt_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0728'); // EGR cooler inlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0729'); // EGR cooler outlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_out_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('072B'); // DPF soot loading
      if (b.isNotEmpty) {
        out['gm_dpf_soot'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('072C'); // DPF diff pressure
      if (b.isNotEmpty) {
        out['gm_dpf_dp'] = '${((b['A']! * 256 + b['B']!) * 0.01).toStringAsFixed(2)} kPa';
      }
      b = await readMode22Pid('072D'); // DPF inlet temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_dpf_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('073A'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['gm_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('073B', numBytes: 1); // Oil life
      if (b.isNotEmpty) {
        out['gm_oil_life'] = '${b['A']!}%';
      }
      b = await readMode22Pid('0741'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_trans_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0739', numBytes: 1); // Water in fuel
      if (b.isNotEmpty) {
        out['gm_water_fuel'] = (b['A']! & 1) == 1 ? 'DETECTED ⚠️' : 'OK';
      }

    } catch (e) {
      debugPrint('Duramax LMM read error: $e');
    } finally {
      await _cmd('ATSH 7DF'); await _cmd('ATST00');
    }
    return out;
  }

  // ── DURAMAX LML (2011–2016) ──────────────────────────────
  /// Added SCR/DEF system. DEF level + NOx critical.
  Future<Map<String, String>> _readGmLml() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96'); await _cmd('ATH0'); await _cmd('ATS0');

      var b = await readMode22Pid('0804'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_oil_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0811'); // Rail pressure actual
      if (b.isNotEmpty) {
        final mpa = (b['A']! * 256 + b['B']!) * 100.0 / 1000000;
        out['gm_rail_mpa'] = '${mpa.toStringAsFixed(0)} MPa';
      }
      b = await readMode22Pid('080B'); // Boost actual
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.01 * 0.1450377;
        out['gm_boost_psi'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('080D'); // VGT actual
      if (b.isNotEmpty) {
        out['gm_vgt_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0828'); // EGR cooler inlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0829'); // EGR cooler outlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_out_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('082B'); // DPF soot
      if (b.isNotEmpty) {
        out['gm_dpf_soot'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('082C'); // DPF diff pressure
      if (b.isNotEmpty) {
        out['gm_dpf_dp'] = '${((b['A']! * 256 + b['B']!) * 0.01).toStringAsFixed(2)} kPa';
      }
      b = await readMode22Pid('083A', numBytes: 1); // DEF level
      if (b.isNotEmpty) {
        out['gm_def_level'] = '${(b['A']! * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('083B', numBytes: 1); // DEF quality
      if (b.isNotEmpty) {
        out['gm_def_quality'] = '${(b['A']! * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0837'); // NOx upstream
      if (b.isNotEmpty) {
        out['gm_nox_up'] = '${((b['A']! * 256 + b['B']!) * 0.05).toStringAsFixed(0)} ppm';
      }
      b = await readMode22Pid('0838'); // NOx downstream
      if (b.isNotEmpty) {
        out['gm_nox_dn'] = '${((b['A']! * 256 + b['B']!) * 0.05).toStringAsFixed(0)} ppm';
      }
      b = await readMode22Pid('084A'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['gm_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('084B', numBytes: 1); // Oil life
      if (b.isNotEmpty) {
        out['gm_oil_life'] = '${b['A']!}%';
      }
      b = await readMode22Pid('0851'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_trans_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }

    } catch (e) {
      debugPrint('Duramax LML read error: $e');
    } finally {
      await _cmd('ATSH 7DF'); await _cmd('ATST00');
    }
    return out;
  }

  // ── DURAMAX L5P (2017–PRESENT) ───────────────────────────
  /// CP4.2 pump + full emissions. CP4 wear index is critical.
  Future<Map<String, String>> _readGmL5p() async {
    final out = <String, String>{};
    try {
      await _cmd('ATST96'); await _cmd('ATH0'); await _cmd('ATS0');

      var b = await readMode22Pid('0904'); // Oil temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_oil_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('0914'); // Rail pressure actual
      if (b.isNotEmpty) {
        final mpa = (b['A']! * 256 + b['B']!) * 100.0 / 1000000;
        out['gm_rail_mpa'] = '${mpa.toStringAsFixed(0)} MPa';
      }
      b = await readMode22Pid('090B'); // Boost actual
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.01 * 0.1450377;
        out['gm_boost_psi'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('090D'); // VGT actual
      if (b.isNotEmpty) {
        out['gm_vgt_pct'] = '${((b['A']! * 256 + b['B']!) * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0919'); // CP4 wear index
      if (b.isNotEmpty) {
        out['gm_cp4_wear'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0933'); // EGR cooler inlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_in_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0934'); // EGR cooler outlet
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_egr_out_c'] = '${c.toStringAsFixed(1)}°C';
      }
      b = await readMode22Pid('0938'); // DPF soot
      if (b.isNotEmpty) {
        out['gm_dpf_soot'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0939'); // DPF diff pressure
      if (b.isNotEmpty) {
        out['gm_dpf_dp'] = '${((b['A']! * 256 + b['B']!) * 0.01).toStringAsFixed(2)} kPa';
      }
      b = await readMode22Pid('0949', numBytes: 1); // DEF level
      if (b.isNotEmpty) {
        out['gm_def_level'] = '${(b['A']! * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('094A', numBytes: 1); // DEF quality
      if (b.isNotEmpty) {
        out['gm_def_quality'] = '${(b['A']! * 100 / 255).toStringAsFixed(1)}%';
      }
      b = await readMode22Pid('0946'); // NOx upstream
      if (b.isNotEmpty) {
        out['gm_nox_up'] = '${((b['A']! * 256 + b['B']!) * 0.05).toStringAsFixed(0)} ppm';
      }
      b = await readMode22Pid('0947'); // NOx downstream
      if (b.isNotEmpty) {
        out['gm_nox_dn'] = '${((b['A']! * 256 + b['B']!) * 0.05).toStringAsFixed(0)} ppm';
      }
      b = await readMode22Pid('0956'); // Oil pressure
      if (b.isNotEmpty) {
        final psi = (b['A']! * 256 + b['B']!) * 0.58 * 0.1450377;
        out['gm_oil_press'] = '${psi.toStringAsFixed(1)} psi';
      }
      b = await readMode22Pid('0957', numBytes: 1); // Oil life
      if (b.isNotEmpty) {
        out['gm_oil_life'] = '${b['A']!}%';
      }
      b = await readMode22Pid('0960'); // Trans fluid temp
      if (b.isNotEmpty) {
        final c = (b['A']! * 256 + b['B']!) * 0.1 - 40;
        out['gm_trans_temp'] = '${(c * 9/5 + 32).toStringAsFixed(1)}°F';
      }
      b = await readMode22Pid('097C'); // Fuel dilution in oil
      if (b.isNotEmpty) {
        out['gm_fuel_dilution'] = '${((b['A']! * 256 + b['B']!) * 100 / 65535).toStringAsFixed(1)}%';
      }

    } catch (e) {
      debugPrint('Duramax L5P read error: $e');
    } finally {
      await _cmd('ATSH 7DF'); await _cmd('ATST00');
    }
    return out;
  }

  Future<Map<String, String>> fullScan(bool engineRunning) async {
    final data = <String, String>{};

    data['vin'] = await readVin();

    // Drain after multi-frame VIN read before sending 0100.
    // Without this, residual VIN bytes corrupt the PID bitmask response
    // and make supported PIDs appear empty — hiding RPM/coolant/speed/throttle.
    await drainAdapter();
    await detectSupportedPids();

    // Use a permissive fallback: if bitmask came back with fewer than 3
    // PIDs it's probably a failed read — treat as if all PIDs are supported.
    final sp = supportedPids;
    final permissive = sp == null || sp.pids.length < 3;

    data['battery'] = '${(await readBattery()).toStringAsFixed(1)}V';

    if (engineRunning) {
      if (permissive || sp!.has('0C')) {
        data['rpm'] = '${await readRpm()} rpm';
      }
      if (permissive || sp!.has('05')) {
        data['coolant_temp'] = '${await readCoolantTemp()}°C';
      }
      if (permissive || sp!.has('0D')) {
        data['speed'] = '${await readSpeed()} km/h';
      }
      if (permissive || sp!.has('11')) {
        data['throttle'] = '${(await readThrottle()).toStringAsFixed(1)}%';
      }
      if (permissive || sp!.has('2F')) {
        data['fuel_level'] = '${(await readFuelLevel()).toStringAsFixed(1)}%';
      }
    }

    final dtcs = await readDtcs();
    data['dtc_count'] = '${dtcs.length}';
    data['dtcs'] = dtcs.join(',');

    return data;
  }
}

// ─────────────────────────────────────────
//  AWS SIGNATURE V4
// ─────────────────────────────────────────
class AwsSigV4Signer {
  final String accessKey;
  final String secretKey;
  final String region;
  final String service;

  AwsSigV4Signer({
    required this.accessKey,
    required this.secretKey,
    required this.region,
    required this.service,
  });

  Map<String, String> sign({
    required String method,
    required Uri uri,
    required String body,
  }) {
    final now = DateTime.now().toUtc();
    final dateStamp = _dateStamp(now);
    final amzDate = _amzDate(now);
    const contentType = 'application/json';
    final payloadHash = _sha256Hex(body);

    final headers = {
      'content-type': contentType,
      'host': uri.host,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
    };

    final signedHeaders = headers.keys.toList()..sort();
    final canonicalHeaders =
        signedHeaders.map((k) => '$k:${headers[k]}').join('\n') + '\n';
    final signedHeadersStr = signedHeaders.join(';');

    final canonicalRequest = [
      method,
      uri.path.replaceAll(':', '%3A'),
      uri.query,
      canonicalHeaders,
      signedHeadersStr,
      payloadHash,
    ].join('\n');

    final credentialScope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      _sha256Hex(canonicalRequest),
    ].join('\n');

    final signingKey = _deriveKey(secretKey, dateStamp, region, service);
    final signature = _hmacHex(signingKey, stringToSign);

    return {
      'Content-Type': contentType,
      'Host': uri.host,
      'X-Amz-Date': amzDate,
      'X-Amz-Content-Sha256': payloadHash,
      'Authorization':
      'AWS4-HMAC-SHA256 Credential=$accessKey/$credentialScope, '
          'SignedHeaders=$signedHeadersStr, Signature=$signature',
    };
  }

  Uint8List _deriveKey(
      String secret, String date, String region, String service) {
    final kSecret = utf8.encode('AWS4$secret');
    final kDate = _hmacBytes(kSecret, date);
    final kRegion = _hmacBytes(kDate, region);
    final kService = _hmacBytes(kRegion, service);
    return _hmacBytes(kService, 'aws4_request');
  }

  Uint8List _hmacBytes(List<int> key, String data) =>
      Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode(data)).bytes);

  String _hmacHex(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).toString();

  String _sha256Hex(String data) =>
      sha256.convert(utf8.encode(data)).toString();

  String _dateStamp(DateTime dt) =>
      '${dt.year}${_pad(dt.month)}${_pad(dt.day)}';

  String _amzDate(DateTime dt) =>
      '${_dateStamp(dt)}T${_pad(dt.hour)}${_pad(dt.minute)}${_pad(dt.second)}Z';

  String _pad(int n) => n.toString().padLeft(2, '0');
}

// ─────────────────────────────────────────
//  NOVA AI SERVICE
// ─────────────────────────────────────────

// ─────────────────────────────────────────
//  VEHICLE PROFILE SCREEN
// ─────────────────────────────────────────
class VehicleProfileScreen extends StatefulWidget {
  final BluetoothDevice? device;    // BLE device (null if classic)
  final String? classicMac;         // Classic BT MAC (null if BLE)
  final bool engineRunning;

  const VehicleProfileScreen({
    super.key,
    this.device,
    this.classicMac,
    required this.engineRunning,
  }) : assert(device != null || classicMac != null,
  'Must provide either device or classicMac');

  @override
  State<VehicleProfileScreen> createState() => _VehicleProfileScreenState();
}

class _VehicleProfileScreenState extends State<VehicleProfileScreen> {
  final _obd = OBD2Service();
  VehicleProfile? _profile;
  String _status = 'Initializing OBD2 connection...';
  bool _loading = true;
  String? _error;
  Timer? _liveTimer;
  // Manual VIN override — used when tuner has replaced the PCM VIN slot
  String? _manualVin;

  // Powerstroke PIDs — read silently in background after scan
  // Not shown on this page; forwarded to AI Overview + Stats for Nerds
  Map<String, String> _powerstrokePids = {};
  bool _psLoading = false;
  int _psGen = 60; // detected generation: 73, 60, 64, or 67

  // Toyota PIDs — same pattern, read silently for Toyota/Lexus/Scion
  Map<String, String> _toyotaPids = {};
  bool _toyotaLoading = false;

  // GM PIDs — read silently for Chevy/GMC/Cadillac/Buick
  Map<String, String> _gmPids = {};
  bool _gmLoading = false;
  String _gmGen = 'gas';


  @override
  void initState() {
    super.initState();
    _runScan();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }


  /// Pure NHTSA VIN decode — no AI in the chain.
  /// Falls back to a static map of common makes if NHTSA is unreachable.
  Future<Map<String, String>> _decodeVinNhtsa(String vin) async {
    if (vin != 'UNKNOWN' && vin.length == 17) {
      try {
        final url = Uri.parse(
            'https://vpic.nhtsa.dot.gov/api/vehicles/decodevin/$vin?format=json');
        final resp = await http.get(url).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final data    = jsonDecode(resp.body);
          final results = data['Results'] as List;
          String v(String name) {
            final m = results.firstWhere(
                  (r) => r['Variable'] == name && r['Value'] != null && r['Value'] != '',
              orElse: () => {'Value': ''},
            );
            return m['Value'] ?? '';
          }
          final year  = v('Model Year');
          final make  = v('Make');
          final model = v('Model');
          if (year.isNotEmpty && make.isNotEmpty && model.isNotEmpty) {
            final eng  = v('Displacement (L)');
            final cyl  = v('Engine Number of Cylinders');
            final fuel = v('Fuel Type - Primary');
            final trns = v('Transmission Style');
            final drv  = v('Drive Type');
            final engStr = eng.isNotEmpty
                ? '${double.tryParse(eng)?.toStringAsFixed(1) ?? eng}L'
                '${cyl.isNotEmpty ? " V$cyl" : ""}'
                : 'Unknown';
            return {
              'year': year,
              'make': make[0].toUpperCase() + make.substring(1).toLowerCase(),
              'model': model,
              'engine': engStr.trim(),
              'fuelType': fuel.isNotEmpty ? fuel : 'Gasoline',
              'transmission': trns.isNotEmpty ? trns : drv,
            };
          }
        }
      } catch (e) {
        debugPrint('NHTSA decode error: $e');
      }
    }
    // Static fallback — WMI (first 3 chars of VIN) → make
    final wmi = vin.length >= 3 ? vin.substring(0, 3).toUpperCase() : '';
    const wmiMap = {
      '1FT': 'Ford',   '1FA': 'Ford',   '1FM': 'Ford',
      '1GC': 'Chevrolet', '1G1': 'Chevrolet', '2G1': 'Chevrolet',
      '1HG': 'Honda',  '2HG': 'Honda',  'JHM': 'Honda',
      'JTD': 'Toyota', 'JTE': 'Toyota', '4T1': 'Toyota', '5TD': 'Toyota',
      '1N4': 'Nissan', 'JN1': 'Nissan', '3N1': 'Nissan',
      'WBA': 'BMW',    'WBS': 'BMW',
      'WDD': 'Mercedes-Benz', 'WDC': 'Mercedes-Benz',
      '1C4': 'Chrysler', '1C6': 'Ram', '2C3': 'Dodge', '1B3': 'Dodge',
      'SAL': 'Land Rover', 'SAJ': 'Jaguar',
      'YV1': 'Volvo',  'YV4': 'Volvo',
    };
    return {
      'year': 'Unknown',
      'make': wmiMap[wmi] ?? 'Unknown',
      'model': 'Unknown',
      'engine': 'Unknown',
      'fuelType': 'Gasoline',
      'transmission': 'Unknown',
    };
  }

  /// Shows a dialog to manually enter/override the VIN.
  /// Used when a tuner (Edge, SCT, etc.) has replaced the PCM VIN slot.
  Future<void> _showVinEditDialog(String currentVin) async {
    final ctrl = TextEditingController(
        text: _manualVin ?? (currentVin == 'UNKNOWN' ? '' : currentVin));
    String? errorText;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.bgCard,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: AppColors.border)),
          title: const Text('Enter VIN Manually',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                currentVin == 'UNKNOWN'
                    ? 'VIN could not be read from the vehicle.\nThis is common with aftermarket tunes (Edge, SCT, etc.) that overwrite the PCM VIN slot.'
                    : 'The VIN read from the vehicle appears to be a tuner calibration ID, not the real VIN.\nEnter your actual 17-character VIN.',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                maxLength: 17,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    color: AppColors.textPrimary,
                    letterSpacing: 2,
                    fontSize: 14),
                decoration: InputDecoration(
                  hintText: '17-CHARACTER VIN',
                  hintStyle: TextStyle(
                      color: AppColors.textMuted.withOpacity(0.5),
                      fontSize: 12,
                      letterSpacing: 1),
                  errorText: errorText,
                  counterStyle:
                  const TextStyle(color: AppColors.textMuted),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: AppColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                      const BorderSide(color: AppColors.blueElectric)),
                  errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                      const BorderSide(color: AppColors.danger)),
                  focusedErrorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                      const BorderSide(color: AppColors.danger)),
                  filled: true,
                  fillColor: AppColors.bgCard2,
                ),
                onChanged: (_) =>
                    setDialogState(() => errorText = null),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                // Clear manual override — go back to OBD-read VIN
                setState(() => _manualVin = null);
                Navigator.pop(ctx);
              },
              child: const Text('CLEAR OVERRIDE',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 11)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL',
                  style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.blueElectric,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8))),
              onPressed: () async {
                final vin = ctrl.text.trim().toUpperCase();
                // Basic VIN validation
                if (vin.length != 17) {
                  setDialogState(
                          () => errorText = 'VIN must be exactly 17 characters');
                  return;
                }
                if (!RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(vin)) {
                  setDialogState(() =>
                  errorText = 'Invalid characters (I, O, Q not allowed)');
                  return;
                }
                setState(() => _manualVin = vin);
                Navigator.pop(ctx);
                // Re-run the vehicle lookup with the correct VIN
                if (_profile != null) {
                  try {
                    final vehicleInfo = await _decodeVinNhtsa(vin);
                    setState(() {
                      _profile = VehicleProfile(
                        vin: vin,
                        year: vehicleInfo['year'] ?? _profile!.year,
                        make: vehicleInfo['make'] ?? _profile!.make,
                        model: vehicleInfo['model'] ?? _profile!.model,
                        engine: vehicleInfo['engine'] ?? _profile!.engine,
                        fuelType:
                        vehicleInfo['fuelType'] ?? _profile!.fuelType,
                        transmission: vehicleInfo['transmission'] ??
                            _profile!.transmission,
                        engineRunning: _profile!.engineRunning,
                        rawObd: _profile!.rawObd,
                      );
                    });
                    HistoryService.save(ScanRecord.fromProfile(_profile!));
                  } catch (e) {
                    debugPrint('VIN re-decode error: $e');
                  }
                }
              },
              child: const Text('SAVE VIN',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  int _clamp(int val, int lo, int hi) => val < lo ? lo : (val > hi ? hi : val);

  /// Reads Toyota Mode 21 + Mode 01 extended PIDs silently in the background.
  /// Reads GM Mode 22 enhanced PIDs silently in the background.
  Future<void> _fetchGmPids({String gen = 'gas'}) async {
    if (_gmLoading) return;
    _gmLoading = true;
    try {
      _obd.pauseLiveUpdates();
      await Future.delayed(const Duration(milliseconds: 400));

      // Non-GM brands that route through here use the universal reader.
      // GM Duramax generations keep their legacy readers for now since
      // they have custom CAN headers and ECU addresses.
      const legacyGmGens = {'lb7', 'lly_lbz', 'lmm', 'lml', 'l5p', 'gas'};
      Map<String, String> results;

      if (legacyGmGens.contains(gen.toLowerCase())) {
        results = await _obd.readGmPids(gen: gen);
      } else {
        // Universal reader: uses PidRegistry formula + byte count for every
        // make — BMW, Honda, VW, Cummins, Hyundai, Jeep, etc.
        results = await _obd.readManufacturerPids(gen.toUpperCase());
      }
      if (mounted) _gmPids = results;
    } catch (e) {
      debugPrint('Background manufacturer read error: $e');
    } finally {
      _gmLoading = false;
      _obd.resumeLiveUpdates();
    }
  }

  /// Detects Cummins generation string for Dodge/Ram trucks.
  static String _detectCumminsGen(int year, String engine) {
    if (engine.contains('6.7') || year >= 2007) return 'cummins_isb67';
    if (engine.contains('5.9') && year >= 2003)  return 'cummins_cr59';
    if (engine.contains('5.9') && year >= 1998)  return 'cummins_24v';
    if (engine.contains('5.9'))                   return 'cummins_12v';
    if (year >= 2007) return 'cummins_isb67';
    if (year >= 2003) return 'cummins_cr59';
    if (year >= 1998) return 'cummins_24v';
    return 'cummins_12v';
  }

  /// Detects VW TDI generation string.
  static String _detectVwTdiGen(int year) {
    if (year >= 2015) return 'vw_ea288';
    if (year >= 2009) return 'vw_cr';
    if (year >= 2004) return 'vw_pd';
    return 'vw_alh';
  }

  /// Detects Jeep/Chrysler/Dodge/Ram generation string.
  static String _detectJeepGen(String fuel, String engine, String model) {
    final e = engine.toLowerCase();
    final f = fuel.toLowerCase();
    final m = model.toLowerCase();
    // BEV: Wagoneer S
    if (f.contains('electric') || e.contains('electric') ||
        m.contains('wagoneer s')) {
      return 'jeep_wagoneer_s';
    }
    // 4xe PHEV: Wrangler 4xe, Grand Cherokee 4xe, Compass 4xe
    if (f.contains('hybrid') || e.contains('hybrid') ||
        m.contains('4xe') || e.contains('plug')) {
      return 'jeep_4xe';
    }
    // HEMI: 5.7L, 6.4L, 6.2L Hellcat/Demon
    if (e.contains('5.7') || e.contains('6.4') || e.contains('6.2') ||
        e.contains('hemi') || e.contains('hellcat') || e.contains('demon') ||
        e.contains('redeye')) {
      return 'jeep_hemi';
    }
    // Default: Pentastar 3.6L V6 or 2.0T/2.4L
    return 'jeep_gas_pent';
  }

  /// Detects Honda/Acura generation string.
  static String _detectHondaGen(String fuel, String engine, String model) {
    final m = model.toLowerCase();
    final e = engine.toLowerCase();
    // Hybrid / PHEV: Insight, Accord Hybrid, CR-V Hybrid, Clarity PHEV
    if (fuel.contains('hybrid') || fuel.contains('electric') ||
        e.contains('hybrid') || m.contains('insight') ||
        m.contains('clarity')) {
      return 'honda_hybrid';
    }
    // NSX
    if (m.contains('nsx')) return 'honda_nsx';
    // Type R
    if (m.contains('type r') || m.contains('type-r') || e.contains('k20c1')) {
      return 'honda_type_r';
    }
    // All other gas
    return 'honda_gas_k';
  }

  /// Detects Hyundai/Kia/Genesis generation string.
  static String _detectHkgGen(String fuel, String engine, int year) {
    final e = engine.toLowerCase();
    final f = fuel.toLowerCase();
    if (f.contains('electric') || f.contains('hybrid') ||
        e.contains('electric') || e.contains('hybrid') ||
        e.contains('ev') || e.contains('ioniq')) {
      return 'hkg_hybrid_ev';
    }
    if (f.contains('diesel') || e.contains('crdi') || e.contains('diesel')) {
      return 'hkg_diesel';
    }
    // Turbo gas: Smartstream G1.6T, G2.5T, 3.3T
    if (e.contains('turbo') || e.contains('1.6t') || e.contains('2.5t') ||
        e.contains('3.3t') || e.contains('t-gdi')) {
      return 'hkg_turbo';
    }
    return 'hkg_gas_na';
  }

  /// Detects BMW generation string.
  static String _detectBmwGen(String fuel, String engine, int year) {
    // PHEV / EV: i3, i4, iX, 530e, 740e, X5 45e
    if (engine.contains('electric') || engine.contains('hybrid') ||
        engine.contains('plug') || engine.contains(' e') ||
        engine.contains('i3') || engine.contains('i4') ||
        engine.contains('ix')) {
      return 'bmw_phev_hv';
    }
    // Diesel: N57/B57 engines
    if (fuel.contains('diesel') || engine.contains('diesel') ||
        engine.contains('n57') || engine.contains('b57') ||
        engine.contains('d') ) {
      return 'bmw_n57_diesel';
    }
    // Gas N-series (default)
    return 'bmw_gas_n';
  }

  /// Reads Toyota Mode 21 + Mode 01 extended PIDs silently in the background.
  Future<void> _fetchToyotaPids() async {
    if (_toyotaLoading) return;
    _toyotaLoading = true;
    try {
      _obd.pauseLiveUpdates();
      await Future.delayed(const Duration(milliseconds: 400));
      final results = await _obd.readToyotaPids();
      if (mounted) _toyotaPids = results;
    } catch (e) {
      debugPrint('Background Toyota read error: $e');
    } finally {
      _toyotaLoading = false;
      _obd.resumeLiveUpdates();
    }
  }

  /// Reads all Powerstroke Mode 22 PIDs silently in the background.
  /// Results stored in [_powerstrokePids] and merged into AI Overview + Stats.
  Future<void> _fetchPowerstrokePids({int gen = 60}) async {
    if (_psLoading) return;
    _psLoading = true;
    try {
      _obd.pauseLiveUpdates();
      await Future.delayed(const Duration(milliseconds: 400));
      final results = await _obd.readPowerstrokePids(gen: gen);
      if (mounted) {
        // No setState needed — data is only read by AI Overview and Stats
        _powerstrokePids = results;
      }
    } catch (e) {
      debugPrint('Background PS read error: $e');
    } finally {
      _psLoading = false;
      _obd.resumeLiveUpdates();
    }
  }

  Future<void> _runScan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      setState(() => _status = 'Connecting to OBD2 adapter...');
      final bool ok;
      if (widget.classicMac != null) {
        ok = await _obd.initializeClassic(widget.classicMac!);
      } else {
        ok = await _obd.initialize(widget.device!);
      }
      if (!ok) {
        throw Exception(
            'Could not initialize OBD2 adapter.\nMake sure the dongle is powered on and in range.');
      }

      setState(() => _status = 'Reading vehicle data...');
      final data = await _obd.fullScan(widget.engineRunning);
      final vin = (_manualVin != null && _manualVin!.length == 17)
          ? _manualVin!
          : (data['vin'] ?? 'UNKNOWN');

      setState(() => _status = 'Identifying your vehicle...');
      final vehicleInfo = await _decodeVinNhtsa(vin);

      setState(() {
        _profile = VehicleProfile(
          vin: vin,
          year: vehicleInfo['year']!,
          make: vehicleInfo['make']!,
          model: vehicleInfo['model']!,
          engine: vehicleInfo['engine']!,
          fuelType: vehicleInfo['fuelType']!,
          transmission: vehicleInfo['transmission']!,
          engineRunning: widget.engineRunning,
          rawObd: data,
        );
        _loading = false;
      });

      HistoryService.save(ScanRecord.fromProfile(_profile!));
      _startLiveUpdates();

      // Silently read manufacturer-specific PIDs in background
      // Data goes to AI Overview and Stats for Nerds — not shown here
      final fuel  = vehicleInfo['fuelType']?.toLowerCase() ?? '';
      final eng   = vehicleInfo['engine']?.toLowerCase() ?? '';
      final make  = vehicleInfo['make']?.toLowerCase() ?? '';
      final year  = int.tryParse(vehicleInfo['year'] ?? '') ?? 0;

      // ── Ford Powerstroke diesel ──────────────────────────
      if ((make.contains('ford') || make.contains('lincoln')) &&
          (fuel.contains('diesel') || eng.contains('diesel'))) {
        final gen = OBD2Service.detectPowerstrokeGen(vehicleInfo['engine'] ?? '');
        _psGen = gen;
        _fetchPowerstrokePids(gen: gen);

        // ── Dodge / Ram Cummins diesel ───────────────────────
      } else if ((make.contains('dodge') || make.contains('ram')) &&
          (fuel.contains('diesel') || eng.contains('diesel') ||
              eng.contains('cummins'))) {
        // Detect Cummins generation by year
        final cumminsGen = _detectCumminsGen(year, eng);
        _gmGen = cumminsGen; // reuse _gmGen slot for Cummins
        _fetchGmPids(gen: cumminsGen);

        // ── Toyota / Lexus / Scion ───────────────────────────
      } else if (make.contains('toyota') || make.contains('lexus') ||
          make.contains('scion')) {
        _fetchToyotaPids();

        // ── GM (Chevy / GMC / Cadillac / Buick) ─────────────
      } else if (make.contains('chevrolet') || make.contains('chevy') ||
          make.contains('gmc') || make.contains('cadillac') ||
          make.contains('buick')) {
        final gen = OBD2Service.detectGmGen(
          fuelType: vehicleInfo['fuelType'] ?? '',
          engine: vehicleInfo['engine'] ?? '',
          year: vehicleInfo['year'] ?? '',
        );
        _gmGen = gen;
        _fetchGmPids(gen: gen);

        // ── VW / Audi / Skoda / SEAT TDI ────────────────────
      } else if ((make.contains('volkswagen') || make.contains('vw') ||
          make.contains('audi') || make.contains('skoda') ||
          make.contains('seat')) &&
          (fuel.contains('diesel') || eng.contains('tdi') ||
              eng.contains('diesel'))) {
        final vwGen = _detectVwTdiGen(year);
        _gmGen = vwGen;
        _fetchGmPids(gen: vwGen);

        // ── BMW / Mini ───────────────────────────────────────
      } else if (make.contains('bmw') || make.contains('mini')) {
        final bmwGen = _detectBmwGen(fuel, eng, year);
        _gmGen = bmwGen;
        _fetchGmPids(gen: bmwGen);

        // ── Honda / Acura ────────────────────────────────────
      } else if (make.contains('honda') || make.contains('acura')) {
        final hondaGen = _detectHondaGen(fuel, eng, vehicleInfo['model'] ?? '');
        _gmGen = hondaGen;
        _fetchGmPids(gen: hondaGen);

        // ── Hyundai / Kia / Genesis ──────────────────────────
      } else if (make.contains('hyundai') || make.contains('kia') ||
          make.contains('genesis')) {
        final hkgGen = _detectHkgGen(fuel, eng, year);
        _gmGen = hkgGen;
        _fetchGmPids(gen: hkgGen);

        // ── Jeep / Chrysler / Dodge / Ram (Stellantis gas) ───
      } else if (make.contains('jeep') || make.contains('chrysler') ||
          make.contains('dodge') || make.contains('ram')) {
        final jeepGen = _detectJeepGen(fuel, eng, vehicleInfo['model'] ?? '');
        _gmGen = jeepGen;
        _fetchGmPids(gen: jeepGen);
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _startLiveUpdates() {
    _liveTimer = Timer.periodic(
        Duration(milliseconds: appSettings.updateIntervalMs), (_) async {
      if (!mounted || _profile == null) return;
      if (_obd._paused) return; // debug screen is using the bus — skip this tick
      final updated = Map<String, String>.from(_profile!.rawObd);
      final sp = _obd.supportedPids;

      updated['battery'] =
      '${(await _obd.readBattery()).toStringAsFixed(1)}V';

      if (_profile!.engineRunning) {
        if (sp == null || sp.has('0C')) {
          updated['rpm'] = '${await _obd.readRpm()} rpm';
        }
        if (sp == null || sp.has('05')) {
          final tempC = await _obd.readCoolantTemp();
          updated['coolant_temp'] = appSettings.formatTemp(tempC);
        }
        if (sp == null || sp.has('0D')) {
          final kmh = await _obd.readSpeed();
          updated['speed'] = appSettings.formatSpeed(kmh);
        }
        if (sp == null || sp.has('11')) {
          updated['throttle'] =
          '${(await _obd.readThrottle()).toStringAsFixed(1)}%';
        }
        if (sp == null || sp.has('2F')) {
          updated['fuel_level'] =
          '${(await _obd.readFuelLevel()).toStringAsFixed(1)}%';
        }
      }


      if (mounted) {
        setState(() {
          _profile = VehicleProfile(
            vin: _profile!.vin,
            year: _profile!.year,
            make: _profile!.make,
            model: _profile!.model,
            engine: _profile!.engine,
            fuelType: _profile!.fuelType,
            transmission: _profile!.transmission,
            engineRunning: _profile!.engineRunning,
            rawObd: updated,
          );

        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: _loading
              ? _buildLoading()
              : _error != null
              ? _buildError()
              : _buildProfile(),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: AppColors.blueElectric),
            const SizedBox(height: 24),
            Text(_status,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                    height: 1.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.error_outline_rounded,
                  color: AppColors.danger, size: 36),
            ),
            const SizedBox(height: 20),
            const Text('Scan Failed',
                style:
                TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    height: 1.5)),
            const SizedBox(height: 28),
            PrimaryButton(
              label: 'Try Again',
              icon: Icons.refresh_rounded,
              onPressed: _runScan,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfile() {
    final p = _profile!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Vehicle Identified',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    Text('Vehicle identified via OBD2',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary)),
                  ],
                ),
              ),
              LiveIndicator(
                color: p.engineRunning
                    ? AppColors.success
                    : AppColors.warning,
                label:
                p.engineRunning ? 'ENGINE ON' : 'ENGINE OFF',
              ),
            ],
          ),

          const SizedBox(height: 24),

          GlassCard(
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 60, height: 60,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: AppColors.primaryGradient),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                              color: AppColors.blueCore.withOpacity(0.4),
                              blurRadius: 16),
                        ],
                      ),
                      child: const Icon(Icons.directions_car_rounded,
                          color: Colors.white, size: 30),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.displayName,
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(p.engineDisplay,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary)),
                          const SizedBox(height: 2),
                          Text(p.transmission,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.bgCard2.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text('VIN',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: AppColors.textMuted,
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.w700)),
                          const Spacer(),
                          GestureDetector(
                            onTap: () => _showVinEditDialog(p.vin),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.blueElectric.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: AppColors.blueElectric.withOpacity(0.3)),
                              ),
                              child: const Text('EDIT',
                                  style: TextStyle(
                                      fontSize: 8,
                                      color: AppColors.blueElectric,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _manualVin ?? p.vin,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  color: _manualVin != null
                                      ? AppColors.success
                                      : (p.vin == 'UNKNOWN'
                                      ? AppColors.warning
                                      : AppColors.blueElectric),
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1),
                            ),
                          ),
                          if (p.vin == 'UNKNOWN' || _manualVin != null)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Text('✎ manual',
                                  style: TextStyle(
                                      fontSize: 8,
                                      color: AppColors.textMuted)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          const SectionLabel('Live Readings'),

          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.6,
            children: [
              if (p.rawObd['rpm'] != null)
                _ObdChip(
                    label: 'RPM',
                    value: p.rawObd['rpm']!,
                    color: AppColors.blueBright),
              if (p.rawObd['coolant_temp'] != null)
                _ObdChip(
                    label: 'Coolant',
                    value: p.rawObd['coolant_temp']!,
                    color: AppColors.warning),
              if (p.rawObd['battery'] != null)
                _ObdChip(
                    label: 'Battery',
                    value: p.rawObd['battery']!,
                    color: AppColors.success),
              if (p.rawObd['fuel_level'] != null)
                _ObdChip(
                    label: 'Fuel',
                    value: p.rawObd['fuel_level']!,
                    color: AppColors.blueElectric),
              if (p.rawObd['speed'] != null)
                _ObdChip(
                    label: 'Speed',
                    value: p.rawObd['speed']!,
                    color: AppColors.violetLight),
              if (p.rawObd['throttle'] != null)
                _ObdChip(
                    label: 'Throttle',
                    value: p.rawObd['throttle']!,
                    color: AppColors.teal),
            ],
          ),

          const SizedBox(height: 20),
          const SectionLabel('Fault Codes'),

          GlassCard(
            child: Row(
              children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: (int.tryParse(
                        p.rawObd['dtc_count'] ?? '0') ??
                        0) >
                        0
                        ? AppColors.danger.withOpacity(0.15)
                        : AppColors.success.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    (int.tryParse(p.rawObd['dtc_count'] ?? '0') ?? 0) > 0
                        ? Icons.warning_rounded
                        : Icons.check_circle_rounded,
                    color:
                    (int.tryParse(p.rawObd['dtc_count'] ?? '0') ?? 0) >
                        0
                        ? AppColors.danger
                        : AppColors.success,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p.rawObd['dtc_count'] ?? 0} Fault Code(s) Found',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        (p.rawObd['dtcs'] ?? '').isEmpty
                            ? 'No active fault codes — all clear!'
                            : (p.rawObd['dtcs'] ?? '')
                            .replaceAll(',', '  '),
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.blueElectric,
                            fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          const SizedBox(height: 10),
          PrimaryButton(
            label: 'AI Overview',
            icon: Icons.auto_awesome_rounded,
            onPressed: () {
              // Merge all manufacturer-specific PIDs into rawObd so Nova sees them
              final mergedObd = Map<String, String>.from(_profile!.rawObd)
                ..addAll(_powerstrokePids)
                ..addAll(_toyotaPids)
                ..addAll(_gmPids);
              final enrichedProfile = VehicleProfile(
                vin: _profile!.vin,
                year: _profile!.year,
                make: _profile!.make,
                model: _profile!.model,
                engine: _profile!.engine,
                fuelType: _profile!.fuelType,
                transmission: _profile!.transmission,
                engineRunning: _profile!.engineRunning,
                rawObd: mergedObd,
              );
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AiOverviewScreen(
                    vehicleProfile: enrichedProfile,
                    obdService: _obd,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          SecondaryButton(
            label: 'Stats for Nerds',
            icon: Icons.bar_chart_rounded,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatsScreen(
                    vehicleProfile: _profile!,
                    obd: _obd,
                    powerstrokePids: _powerstrokePids,
                    toyotaPids: _toyotaPids,
                    gmPids: _gmPids,
                    gmGen: _gmGen,
                    psGen: _psGen,
                  ),
                ),
              );
            },
          ),
          if (appSettings.showDebugButton) ...[
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'OBD2 Debug Console',
              icon: Icons.terminal_rounded,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DebugScreen(
                          vehicleProfile: _profile,
                          mainObdService: _obd,
                        ),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 20),
        ],
      ),
    );
  }
} // end _VehicleProfileScreenState

class _ObdChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _ObdChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.bgCard2.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 9,
                  color: AppColors.textMuted,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }
}