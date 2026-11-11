import 'dart:convert';
import 'dart:typed_data';

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

/// cmd/nfc_job: the PC asks this phone to handle one tag (it decides everything else).
class NfcJob {
  NfcJob({required this.jobId, required this.mode, required this.mac, required this.seq});

  final String jobId;

  /// 'write' (Verification 1: write the signed sticker), 'erase' (Verification 1: make the tag new
  /// again) or 'verify' (Verification 2: read only).
  final String mode;
  final String mac;
  final String seq;

  bool get isWrite => mode == 'write';
  bool get isErase => mode == 'erase';
  String get title => switch (mode) {
        'write' => 'Verification 1 · write signed sticker',
        'erase' => 'Verification 1 · erase tag',
        _ => 'Verification 2 · verify sticker',
      };

  factory NfcJob.fromJson(Map<String, dynamic> json) => NfcJob(
        jobId: '${json['job_id'] ?? ''}',
        mode: const {'write', 'erase'}.contains(json['mode']) ? json['mode'] as String : 'verify',
        mac: '${json['mac'] ?? ''}',
        seq: '${json['seq'] ?? ''}',
      );
}

/// cmd/nfc_job_reply: what to write and the tag password - or why the tag was refused.
/// [pwd] / [pack] live in memory only for this job and are wiped afterwards.
class NfcJobReply {
  NfcJobReply({required this.jobId, required this.ok, this.reason = '', this.writePage, this.writeData, this.pwd, this.pack, this.lock = false});

  final String jobId;
  final bool ok;
  final String reason;
  final int? writePage;
  final Uint8List? writeData;
  final Uint8List? pwd;
  final Uint8List? pack;

  /// Lock the tag after writing (AUTH0 = 02; reads stay open). Set by the PC (Settings › Lock tags).
  final bool lock;

  static Uint8List? _hex(Object? text) {
    final s = '${text ?? ''}';
    if (s.isEmpty || s.length.isOdd || !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(s)) return null;
    return Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
  }

  factory NfcJobReply.fromJson(Map<String, dynamic> json) {
    final write = json['write'];
    return NfcJobReply(
      jobId: '${json['job_id'] ?? ''}',
      ok: json['ok'] == true,
      reason: '${json['reason'] ?? ''}',
      writePage: write is Map ? (write['page'] as num?)?.toInt() : null,
      writeData: write is Map ? _hex(write['data']) : null,
      pwd: _hex(json['pwd']),
      pack: _hex(json['pack']),
      lock: json['lock'] == true,
    );
  }

  /// A usable reply: password present, and write data when the job writes.
  String? problem(NfcJob job) {
    if (!ok) return reason.isEmpty ? 'The PC refused the tag' : reason;
    if (pwd?.length != 4 || pack?.length != 2) return 'The PC sent no valid tag password';
    if ((job.isWrite || job.isErase) &&
        (writePage == null || writeData == null || writeData!.isEmpty || writeData!.length % 4 != 0)) {
      return job.isErase ? 'The PC sent no blank data to erase with' : 'The PC sent no data to write';
    }
    return null;
  }

  void wipe() {
    pwd?.fillRange(0, pwd!.length, 0);
    pack?.fillRange(0, pack!.length, 0);
  }
}

class NfcCheck {
  NfcCheck(this.title, this.state, this.detail);

  final String title;

  /// ok / fail / info / skip
  final String state;
  final String detail;
}

/// cmd/nfc_verdict: the PC's judgement of the tag, shown to the operator.
class NfcVerdict {
  NfcVerdict({required this.jobId, required this.ok, required this.headline, required this.uid, required this.checks,
      required this.error, required this.sheet});

  final String jobId;
  final bool ok;
  final String headline;
  final String uid;
  final List<NfcCheck> checks;
  final String error;
  final String sheet;

  factory NfcVerdict.fromJson(Map<String, dynamic> json) => NfcVerdict(
        jobId: '${json['job_id'] ?? ''}',
        ok: json['ok'] == true,
        headline: '${json['headline'] ?? ''}',
        uid: '${json['uid'] ?? ''}',
        checks: [
          for (final c in (json['checks'] as List? ?? const []))
            if (c is Map) NfcCheck('${c['title'] ?? ''}', '${c['state'] ?? ''}', '${c['detail'] ?? ''}'),
        ],
        error: '${json['error'] ?? ''}',
        sheet: '${json['sheet'] ?? ''}',
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
