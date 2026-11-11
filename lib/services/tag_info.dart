import 'dart:convert';
import 'dart:typed_data';

import 'ntag.dart';

/// Decodes the raw pages of an NTAG21x for the NFC Data Viewer (read only, no PC needed).
/// Same rules as the PC (sytrak_gen/core/nfc_sticker.py), except the signature check:
/// that needs the trusted key and is done by the PC (Verification 2).

const userBytes = {'NTAG213': 144, 'NTAG215': 504, 'NTAG216': 888};
const sigType = 'sytrak:s';

class NdefRec {
  NdefRec(this.tnf, this.type, this.payload);

  final int tnf;
  final Uint8List type;
  final Uint8List payload;

  String get typeText => latin1.decode(type, allowInvalid: true);

  String get tnfName =>
      const {0: 'Empty', 1: 'Well-known', 2: 'MIME', 3: 'URI', 4: 'External', 5: 'Unknown', 6: 'Unchanged'}[tnf] ?? 'TNF $tnf';

  /// Body of a Well-Known Text record, else null.
  String? get text {
    if (tnf != 1 || typeText != 'T' || payload.isEmpty) return null;
    final lang = payload[0] & 0x3F;
    if (payload.length < 1 + lang) return null;
    final body = payload.sublist(1 + lang);
    if (payload[0] & 0x80 != 0) {
      return String.fromCharCodes([for (var i = 0; i + 1 < body.length; i += 2) (body[i] << 8) | body[i + 1]]);
    }
    return utf8.decode(body, allowMalformed: true);
  }

  String? get language {
    if (tnf != 1 || typeText != 'T' || payload.isEmpty) return null;
    return latin1.decode(payload.sublist(1, 1 + (payload[0] & 0x3F)), allowInvalid: true);
  }

  bool get isSignature => tnf == 4 && typeText == sigType;
}

class TagInfo {
  TagInfo({required this.uid, required this.version, required this.pages});

  final String uid;
  final Uint8List version;
  final Uint8List pages;

  String? chip;
  int? cfg0;
  int? memory;
  List<NdefRec> records = [];
  String ndefProblem = '';

  bool get uidFixed => uid.length == 14;
  int get pageCount => pages.length ~/ 4;

  Uint8List? page(int n) => (n + 1) * 4 <= pages.length ? pages.sublist(n * 4, n * 4 + 4) : null;

  // --- sticker data ---
  NdefRec? get macRecord => records.where((r) => r.text != null).firstOrNull;
  String? get mac {
    final t = macRecord?.text?.trim();
    return t != null && RegExp(r'^[0-9A-F]{12}$').hasMatch(t) ? t : null;
  }

  NdefRec? get sigRecord => records.where((r) => r.isSignature).firstOrNull;
  bool get sigWellFormed => sigRecord?.payload.length == 49;
  int? get sigVersion => sigWellFormed ? sigRecord!.payload[0] >> 4 : null;
  int? get keyId => sigWellFormed ? sigRecord!.payload[0] & 0x0F : null;
  Uint8List? get sigR => sigWellFormed ? sigRecord!.payload.sublist(1, 25) : null;
  Uint8List? get sigS => sigWellFormed ? sigRecord!.payload.sublist(25, 49) : null;
  String? get signedText => mac != null && uidFixed ? 'sytraknfcv1-$uid-$mac' : null;
  bool get isSyTrakSticker => mac != null && sigRecord != null;

  // --- configuration / protection ---
  Uint8List? get cfg0Bytes => cfg0 == null ? null : page(cfg0!);
  Uint8List? get cfg1Bytes => cfg0 == null ? null : page(cfg0! + 1);
  int? get auth0 => cfg0Bytes?[3];
  int? get access => cfg1Bytes?[0];
  bool? get passwordProtected => auth0 == null ? null : auth0! <= cfg0! + 3;
  bool? get readProtected => access == null ? null : access! & 0x80 != 0;
  bool? get configLocked => access == null ? null : access! & 0x40 != 0;
  int? get authLimit => access == null ? null : access! & 0x07;
  Uint8List? get cc => page(3);
  Uint8List? get staticLock => page(2)?.sublist(2, 4);
  Uint8List? get dynamicLock => cfg0 == null ? null : page(cfg0! - 1)?.sublist(0, 3);
  bool get hasLockBits =>
      (staticLock?.any((b) => b != 0) ?? false) || (dynamicLock?.any((b) => b != 0) ?? false);

  /// "p004  03 4F 91 01  |.O..|  CC" lines.
  List<(String, String, String)> pageLines() {
    final names = <int, String>{0: 'UID', 1: 'UID', 2: 'UID / lock', 3: 'CC'};
    if (cfg0 != null) {
      names.addAll({cfg0! - 1: 'dyn lock', cfg0!: 'CFG0', cfg0! + 1: 'CFG1', cfg0! + 2: 'PWD (reads 0)', cfg0! + 3: 'PACK (reads 0)'});
    }
    return [
      for (var n = 0; n < pageCount; n++)
        (
          'p${n.toString().padLeft(3, '0')}',
          '${page(n)!.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')}'
              '  |${String.fromCharCodes(page(n)!.map((b) => b >= 32 && b < 127 ? b : 46))}|',
          names[n] ?? '',
        ),
    ];
  }
}

TagInfo parseTag(String uid, Uint8List version, Uint8List pages) {
  final info = TagInfo(uid: uid, version: version, pages: pages);
  final chip = version.length >= 8 ? chips[version[6]] : null;
  if (chip != null) {
    info.chip = chip.$1;
    info.cfg0 = chip.$2;
    info.memory = userBytes[chip.$1];
  }
  final start = ndefStartPage * 4;
  final end = info.memory != null ? start + info.memory! : pages.length;
  if (pages.length > start) {
    final (msg, problem) = findNdef(pages.sublist(start, end.clamp(start, pages.length)));
    info.ndefProblem = problem;
    if (msg != null) {
      try {
        info.records = parseRecords(msg);
      } on FormatException catch (e) {
        info.ndefProblem = e.message;
      }
    }
  } else {
    info.ndefProblem = 'no pages read';
  }
  return info;
}

/// The NDEF message in the TLV area (page 4 onward), or null + the reason.
(Uint8List?, String) findNdef(Uint8List user) {
  var i = 0;
  while (i < user.length) {
    final t = user[i];
    if (t == 0x00) {
      i++;
      continue;
    }
    if (t == 0xFE) return (null, 'empty tag (no NDEF message)');
    if (i + 1 >= user.length) break;
    var length = user[i + 1], head = 2;
    if (length == 0xFF) {
      if (i + 3 >= user.length) break;
      length = (user[i + 2] << 8) | user[i + 3];
      head = 4;
    }
    if (i + head + length > user.length) return (null, 'TLV 0x${t.toRadixString(16)} is cut off');
    if (t == 0x03) {
      return length == 0 ? (null, 'empty NDEF message') : (user.sublist(i + head, i + head + length), '');
    }
    i += head + length;
  }
  return (null, 'no NDEF data found');
}

List<NdefRec> parseRecords(Uint8List msg) {
  final out = <NdefRec>[];
  var i = 0;
  while (i < msg.length) {
    final hdr = msg[i];
    if (hdr & 0x20 != 0) throw const FormatException('chunked NDEF record (not supported)');
    final short = hdr & 0x10 != 0, hasId = hdr & 0x08 != 0;
    if (i + 2 >= msg.length) throw const FormatException('NDEF record header cut off');
    final typeLen = msg[i + 1];
    var j = i + 2;
    int payLen;
    if (short) {
      payLen = msg[j];
      j += 1;
    } else {
      if (j + 4 > msg.length) throw const FormatException('NDEF record header cut off');
      payLen = (msg[j] << 24) | (msg[j + 1] << 16) | (msg[j + 2] << 8) | msg[j + 3];
      j += 4;
    }
    final idLen = hasId ? msg[j] : 0;
    if (hasId) j += 1;
    if (j + typeLen + idLen + payLen > msg.length) throw const FormatException('NDEF record cut off');
    out.add(NdefRec(hdr & 0x07, msg.sublist(j, j + typeLen), msg.sublist(j + typeLen + idLen, j + typeLen + idLen + payLen)));
    i = j + typeLen + idLen + payLen;
    if (hdr & 0x40 != 0) break; // ME
  }
  return out;
}

/// Read-only: GET_VERSION and every page. Unknown chips: the first 16 pages, as far as they read.
Future<TagInfo> readTagInfo(NtagTransport io) async {
  final uid = hex(io.uid);
  Uint8List version = Uint8List(0);
  try {
    version = await io.transceive([0x60]);
  } on NtagException {
    await io.reconnect(); // GET_VERSION not supported (older Type 2 tag)
  }
  final chip = version.length >= 8 ? chips[version[6]] : null;
  final last = chip != null ? chip.$2 + 3 : 15;
  final out = BytesBuilder();
  for (var page = 0; page <= last; page += 4) {
    try {
      final data = await io.transceive([0x30, page]);
      if (data.length < 16) break;
      out.add(data);
    } on NtagException {
      if (chip != null) rethrow;
      break;
    }
  }
  final bytes = out.takeBytes();
  final pages = Uint8List.fromList(bytes.sublist(0, bytes.length.clamp(0, (last + 1) * 4)));
  return parseTag(uid, version, pages);
}
