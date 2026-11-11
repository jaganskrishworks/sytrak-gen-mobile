import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sytrak_mobile/services/ntag.dart';

/// Virtual NTAG213 (same behaviour as sytrak_gen/src/sytrak_gen/core/ntag_sim.py FakeNtag).
class FakeNtag implements NtagTransport {
  FakeNtag(String uidHex) : uid = _bytes(uidHex) {
    mem.setRange(0, 3, uid.sublist(0, 3));
    mem.setRange(4, 8, uid.sublist(3, 7));
    mem.setRange(12, 16, [0xE1, 0x10, 0x12, 0x00]);
    mem.setRange(16, 20, [0x03, 0x00, 0xFE, 0x00]);
    mem.setRange(cfg0 * 4, cfg0 * 4 + 4, [0x04, 0x00, 0x00, 0xFF]);
    mem.setRange(cfg0 * 4 + 4, cfg0 * 4 + 8, [0x00, 0x05, 0x00, 0x00]);
    mem.setRange(cfg0 * 4 + 8, cfg0 * 4 + 12, [0xFF, 0xFF, 0xFF, 0xFF]);
  }

  static const cfg0 = 41, pages = 45;
  @override
  final Uint8List uid;
  final mem = Uint8List(pages * 4);
  bool authed = false, halted = false;
  final dropWriteAt = <int>{};
  int reconnects = 0;

  static Uint8List _bytes(String h) =>
      Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

  Uint8List get pwd => mem.sublist((cfg0 + 2) * 4, (cfg0 + 3) * 4);
  int get auth0 => mem[cfg0 * 4 + 3];

  Never _refuse(String why) {
    halted = true;
    throw NtagException(why);
  }

  @override
  Future<void> reconnect() async {
    reconnects++;
    authed = halted = false;
  }

  @override
  Future<Uint8List> transceive(List<int> c) async {
    if (halted) throw NtagException('tag halted');
    switch (c[0]) {
      case 0x60:
        return Uint8List.fromList([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03]);
      case 0x30:
        final out = BytesBuilder();
        for (var i = 0; i < 4; i++) {
          final p = (c[1] + i) % pages;
          out.add(p >= cfg0 + 2 ? [0, 0, 0, 0] : mem.sublist(p * 4, p * 4 + 4));
        }
        return out.takeBytes();
      case 0xA2:
        final p = c[1];
        if (dropWriteAt.remove(p)) _refuse('RF dropout');
        if (p < 2 || p >= pages || (p >= auth0 && !authed)) _refuse('NAK');
        mem.setRange(p * 4, p * 4 + 4, c.sublist(2, 6));
        return Uint8List.fromList([0x0A]);
      case 0x1B:
        if (Uint8List.fromList(c.sublist(1, 5)).toString() == pwd.toString()) {
          authed = true;
          return mem.sublist((cfg0 + 3) * 4, (cfg0 + 3) * 4 + 2);
        }
        _refuse('wrong password');
    }
    _refuse('unknown command');
  }
}

class LossyPwdNtag extends FakeNtag {
  LossyPwdNtag(super.uidHex);

  @override
  Future<Uint8List> transceive(List<int> c) async =>
      c[0] == 0xA2 && c[1] == FakeNtag.cfg0 + 2 ? Uint8List.fromList([0x0A]) : super.transceive(c);
}

final ndef = Uint8List.fromList(List.generate(84, (i) => (i * 7 + 3) & 0xFF));
final pwd = Uint8List.fromList([0xA1, 0xB2, 0xC3, 0xD4]);
final pack = Uint8List.fromList([0x53, 0xB1]);

void main() {
  test('write job: data, password set + validated, tag stays open', () async {
    final tag = FakeNtag('04C34DEA0B1390');
    final driver = NtagDriver(tag);
    final first = await driver.inspect();
    expect(first['uid'], '04C34DEA0B1390');
    expect((first['pages'] as String).length, 45 * 8);
    final result = await driver.writeJob(4, ndef, pwd, pack);
    expect(result['ok'], isTrue, reason: '${result['error']}');
    expect(result['password'], 'validated');
    expect(tag.mem.sublist(16, 16 + 84), ndef);
    expect(tag.pwd, pwd);
    expect(tag.auth0, 0xFF); // NOT locked
    expect(driver.steps.map((s) => s['step']), containsAll(['tag', 'write', 'readback', 'password', 'pwd_auth', 'lock']));
  });

  test('lock: AUTH0 = 02, writes need the password, rewrite works with it', () async {
    final tag = FakeNtag('04C34DEA0B1390');
    final result = await NtagDriver(tag).writeJob(4, ndef, pwd, pack, lock: true);
    expect(result['ok'], isTrue, reason: '${result['error']}');
    expect(result['locked'], isTrue);
    expect(tag.auth0, 0x02);
    expect(tag.mem[(FakeNtag.cfg0 + 1) * 4] & 0xC7, 0); // PROT, CFGLCK, AUTHLIM clear

    await tag.reconnect();
    expect(() => tag.transceive([0xA2, 4, 0, 0, 0, 0]), throwsA(isA<NtagException>()));
    await tag.reconnect();

    final again = await NtagDriver(tag).writeJob(4, ndef, pwd, pack, lock: true);
    expect(again['ok'], isTrue, reason: '${again['error']}');
    expect(again['locked'], isTrue);
  });

  test('never locks when the password check fails', () async {
    final tag = LossyPwdNtag('04C34DEA0B1390'); // ACKs the PWD write but does not keep it
    final result = await NtagDriver(tag).writeJob(4, ndef, pwd, pack, lock: true);
    expect(result['password'], 'failed');
    expect(result['locked'], isFalse);
    expect(tag.auth0, 0xFF);
  });

  test('write resumes from the lost page', () async {
    final tag = FakeNtag('04C34DEA0B1390')..dropWriteAt.add(9);
    final result = await NtagDriver(tag).writeJob(4, ndef, pwd, pack);
    expect(result['ok'], isTrue);
    expect(tag.mem.sublist(16, 16 + 84), ndef);
    expect(tag.reconnects, greaterThanOrEqualTo(2)); // dropout + the password check
  });

  test('verify job: right and wrong password, nothing written', () async {
    final tag = FakeNtag('04C34DEA0B1390');
    await NtagDriver(tag).writeJob(4, ndef, pwd, pack);
    final before = Uint8List.fromList(tag.mem);
    final good = await NtagDriver(tag).verifyJob(pwd, pack);
    expect(good['password'], 'validated');
    final bad = await NtagDriver(tag).verifyJob(Uint8List(4), pack);
    expect(bad['password'], 'failed');
    expect((bad['pages'] as String).isNotEmpty, isTrue); // re-selected after the halt and read
    expect(tag.mem, before);
  });

  test('frozen configuration is refused before writing', () async {
    final tag = FakeNtag('04C34DEA0B1390');
    tag.mem[(FakeNtag.cfg0 + 1) * 4] = 0x40;
    final result = await NtagDriver(tag).writeJob(4, ndef, pwd, pack);
    expect(result['ok'], isFalse);
    expect(result['step'], 'check');
    expect(tag.mem.sublist(16, 20), [0x03, 0x00, 0xFE, 0x00]);
  });
}
