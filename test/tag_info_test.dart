import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sytrak_mobile/services/tag_info.dart';

import 'ntag_test.dart' show FakeNtag;

// nfc_sticker_v1.md §10 test vector (UID 04B34DEA0B1390, MAC E9EBA0ED7C7C)
const specTlv = '034F91010F5402656E45394542413045443743374354'
    '083173797472616B3A73111C5297523D2B705C54D593'
    '433C02747AC29F460B39CEB218344647FDD7427D3095'
    'DBC5F300B26EC99F43E323AE0ACD3BFE';

Uint8List bytes(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

void main() {
  test('reads a SyTrak sticker: MAC, signature, protection', () async {
    final tag = FakeNtag('04B34DEA0B1390');
    tag.mem.setRange(16, 16 + specTlv.length ~/ 2, bytes(specTlv));
    final info = await readTagInfo(tag);
    expect(info.uid, '04B34DEA0B1390');
    expect(info.chip, 'NTAG213');
    expect(info.memory, 144);
    expect(info.pageCount, 45);
    expect(info.mac, 'E9EBA0ED7C7C');
    expect(info.isSyTrakSticker, isTrue);
    expect(info.sigVersion, 1);
    expect(info.keyId, 1);
    expect(info.sigR!.length, 24);
    expect(info.signedText, 'sytraknfcv1-04B34DEA0B1390-E9EBA0ED7C7C');
    expect(info.passwordProtected, isFalse); // AUTH0 FF
    expect(info.configLocked, isFalse);
    expect(info.hasLockBits, isFalse);
    expect(info.records.map((r) => r.typeText), ['T', 'sytrak:s']);
    expect(info.pageLines()[41].$3, 'CFG0');
  });

  test('blank and protected tags', () async {
    final tag = FakeNtag('04000000000001');
    tag.mem[41 * 4 + 3] = 0x02; // AUTH0 = 02
    final info = await readTagInfo(tag);
    expect(info.records, isEmpty);
    expect(info.ndefProblem, contains('empty'));
    expect(info.isSyTrakSticker, isFalse);
    expect(info.passwordProtected, isTrue);
  });

  test('long records and broken data', () {
    final rec = parseRecords(Uint8List.fromList([0xC1, 1, 0, 0, 0, 5, 0x54, 2, 0x65, 0x6E, 0x41, 0x42]));
    expect(rec.single.text, 'AB');
    expect(rec.single.language, 'en');
    expect(() => parseRecords(Uint8List.fromList([0xB1, 1, 3, 0x54])), throwsFormatException);
    expect(findNdef(Uint8List.fromList([0x03, 0x20, 0x91])).$2, contains('cut off'));
  });
}
