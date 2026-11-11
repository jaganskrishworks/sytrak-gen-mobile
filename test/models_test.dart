import 'package:flutter_test/flutter_test.dart';
import 'package:sytrak_mobile/models.dart';

void main() {
  test('parses the MAC-only SyTrak QR', () {
    final qr = QrData.parse('E9EBA0ED7C7C');
    expect(qr.isSyTrak, isTrue);
    expect(qr.mac, 'E9EBA0ED7C7C');
    expect(qr.seq, isNull);
  });

  test('still understands older formats', () {
    final json = QrData.parse('{"mac":"E9:EB:A0:ED:7C:7C","seq":"0001"}');
    expect(json.mac, 'E9EBA0ED7C7C');
    expect(json.seq, '0001');
    expect(QrData.parse('e9eba0ed7c7c;0012').seq, '0012');
    expect(QrData.parse('hello').isSyTrak, isFalse);
  });

  test('verify request matches only the right sticker', () {
    final req = VerifyRequest.fromJson({'mac': 'E9:EB:A0:ED:7C:7C', 'seq': '0001', 'device_type': 'UWB-K4W'});
    expect(req.mac, 'E9EBA0ED7C7C');
    expect(req.matches(QrData.parse('E9EBA0ED7C7C')), isTrue);
    expect(req.matches(QrData.parse('E9EBA0ED7C7D')), isFalse);
    expect(req.matches(QrData.parse('hello')), isFalse);
  });

  test('NFC job and reply parsing', () {
    final job = NfcJob.fromJson({'job_id': 'j-1', 'mode': 'write', 'mac': 'E9EBA0ED7C7C', 'seq': '0001'});
    expect(job.isWrite, isTrue);
    expect(NfcJob.fromJson({'job_id': 'j-2', 'mode': 'anything'}).isWrite, isFalse);

    final reply = NfcJobReply.fromJson({
      'job_id': 'j-1', 'ok': true, 'write': {'page': 4, 'data': '034F9101'}, 'pwd': 'A1B2C3D4', 'pack': '53B1', 'lock': false,
    });
    expect(reply.problem(job), isNull);
    expect(reply.writeData, [0x03, 0x4F, 0x91, 0x01]);
    reply.wipe();
    expect(reply.pwd, [0, 0, 0, 0]);

    expect(NfcJobReply.fromJson({'job_id': 'j-1', 'ok': false, 'reason': 'bad tag'}).problem(job), 'bad tag');
    expect(NfcJobReply.fromJson({'job_id': 'j-1', 'ok': true, 'pwd': 'zz', 'pack': '53B1'}).problem(job), contains('password'));
    expect(NfcJobReply.fromJson({'job_id': 'j-1', 'ok': true, 'pwd': 'A1B2C3D4', 'pack': '53B1'}).problem(job), contains('write'));
  });

  test('NFC erase job needs the blank data', () {
    final erase = NfcJob.fromJson({'job_id': 'j-3', 'mode': 'erase', 'mac': 'E9EBA0ED7C7C'});
    expect(erase.isErase, isTrue);
    expect(erase.isWrite, isFalse);
    expect(erase.title, 'Verification 1 · erase tag');
    final noBlank = NfcJobReply.fromJson({'job_id': 'j-3', 'ok': true, 'pwd': 'A1B2C3D4', 'pack': '53B1'});
    expect(noBlank.problem(erase), contains('blank'));
    final ok = NfcJobReply.fromJson({
      'job_id': 'j-3', 'ok': true, 'mode': 'erase', 'write': {'page': 4, 'data': '0300FE00'}, 'pwd': 'A1B2C3D4', 'pack': '53B1',
    });
    expect(ok.problem(erase), isNull);
  });

  test('NFC verdict parsing', () {
    final v = NfcVerdict.fromJson({
      'job_id': 'j-1', 'ok': true, 'headline': 'STICKER VERIFIED', 'uid': '04C34DEA0B1390',
      'checks': [{'title': 'Signature valid', 'state': 'ok', 'detail': 'key 1'}, 'junk'], 'sheet': 'Saved to sheet row 9',
    });
    expect(v.checks.single.title, 'Signature valid');
    expect(v.sheet, 'Saved to sheet row 9');
  });

  test('parses a discovery beacon', () {
    final s = Station.fromBeacon(
        '{"type":"sytrak-gen","v":1,"station":"SG-PC1","name":"Line 1","mqtt_port":1883,"auth":false,"paired":""}', '192.168.1.5');
    expect(s!.id, 'SG-PC1');
    expect(s.host, '192.168.1.5');
    expect(Station.fromBeacon('SYTRAK_DISCOVER', '1.2.3.4'), isNull);
  });
}
