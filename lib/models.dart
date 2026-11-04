import 'dart:convert';

/// A SyTrak Gen PC station found on the network.
class Station {
  Station({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.auth,
    required this.pairedWith,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final bool auth;

  /// Mobile id the station is currently paired with ('' = free).
  final String pairedWith;

  /// Parses a discovery beacon; [host] is the UDP packet's source address.
  static Station? fromBeacon(String text, String host) {
    try {
      final data = jsonDecode(text);
      if (data is! Map || data['type'] != 'sytrak-gen') return null;
      return Station(
        id: '${data['station']}',
        name: '${data['name'] ?? data['station']}',
        host: host,
        port: (data['mqtt_port'] as num?)?.toInt() ?? 1883,
        auth: data['auth'] == true,
        pairedWith: '${data['paired'] ?? ''}',
      );
    } on FormatException {
      return null;
    }
  }
}

/// Content of a SyTrak QR code: the MAC without colons, e.g. "E9EBA0ED7C7C".
/// (Older codes {"mac":..,"seq":..} are still understood.)
class QrData {
  QrData(this.raw, this.mac, this.seq);

  final String raw;

  /// MAC without colons, upper-case.
  final String? mac;

  /// Only present in older codes - the PC looks the SEQ up by MAC.
  final String? seq;

  bool get isSyTrak => mac != null;

  static final _macRe = RegExp(r'\b([0-9A-Fa-f]{2}(?:[:-]?[0-9A-Fa-f]{2}){5})\b');
  static final _seqRe = RegExp(r'\b(\d{4})\b');

  static String? _normalizeMac(String text) {
    final hex = text.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
    return hex.length == 12 ? hex : null;
  }

  factory QrData.parse(String raw) {
    final text = raw.trim();
    try {
      final data = jsonDecode(text);
      if (data is Map && data['mac'] != null && data['seq'] != null) {
        final seq = int.tryParse('${data['seq']}');
        return QrData(raw, _normalizeMac('${data['mac']}'), seq?.toString().padLeft(4, '0'));
      }
    } on FormatException {
      // not JSON - try plain formats below
    }
    final mac = _macRe.firstMatch(text);
    final seq = _seqRe.firstMatch(text.replaceAll(_macRe, ' '));
    return QrData(raw, mac == null ? null : _normalizeMac(mac.group(1)!), seq?.group(1));
  }
}

/// Station asks this phone to write an NFC tag.
class NfcWriteRequest {
  NfcWriteRequest({required this.seq, required this.mac, required this.data});

  final String seq;
  final String mac;
  final String data;

  factory NfcWriteRequest.fromJson(Map<String, dynamic> json) => NfcWriteRequest(
        seq: '${json['seq'] ?? ''}',
        mac: '${json['mac'] ?? ''}',
        data: '${json['data'] ?? ''}',
      );
}

class ScanAck {
  ScanAck(this.accepted, this.reason);

  final bool accepted;
  final String reason;
}

/// The PC read a device and asks this phone to scan its sticker.
class VerifyRequest {
  VerifyRequest({required this.mac, required this.seq, required this.deviceType});

  /// Expected MAC without colons, upper-case.
  final String mac;
  final String seq;
  final String deviceType;

  factory VerifyRequest.fromJson(Map<String, dynamic> json) => VerifyRequest(
        mac: '${json['mac'] ?? ''}'.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase(),
        seq: '${json['seq'] ?? ''}',
        deviceType: '${json['device_type'] ?? ''}',
      );

  /// Does a scanned sticker belong to the device the PC is holding?
  bool matches(QrData qr) => qr.mac != null && qr.mac == mac;
}

/// The PC's final verdict on the scanned sticker.
class VerifyResult {
  VerifyResult({required this.ok, required this.mac, required this.seq, required this.reason});

  final bool ok;
  final String mac;
  final String seq;
  final String reason;

  factory VerifyResult.fromJson(Map<String, dynamic> json) => VerifyResult(
        ok: json['ok'] == true,
        mac: '${json['mac'] ?? ''}',
        seq: '${json['seq'] ?? ''}',
        reason: '${json['reason'] ?? ''}',
      );
}
