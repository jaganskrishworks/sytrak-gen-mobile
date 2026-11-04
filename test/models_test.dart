import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:sytrak_mobile/models.dart';
import 'package:sytrak_mobile/services/nfc_writer.dart';

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

  test('NFC read request falls back to the MAC as expected text', () {
    expect(NfcReadRequest.fromJson({'seq': '0001', 'mac': 'E9EBA0ED7C7C', 'expected': 'E9EBA0ED7C7C'}).expected, 'E9EBA0ED7C7C');
    expect(NfcReadRequest.fromJson({'mac': 'E9EBA0ED7C7C'}).expected, 'E9EBA0ED7C7C');
  });

  test('parses a discovery beacon', () {
    final s = Station.fromBeacon(
        '{"type":"sytrak-gen","v":1,"station":"SG-PC1","name":"Line 1","mqtt_port":1883,"auth":false,"paired":""}', '192.168.1.5');
    expect(s!.id, 'SG-PC1');
    expect(s.host, '192.168.1.5');
    expect(Station.fromBeacon('SYTRAK_DISCOVER', '1.2.3.4'), isNull);
  });

  test('NDEF text record layout', () {
    final r = NfcWriter.textRecord('AB');
    expect(r.type, [0x54]);
    expect(r.payload, [2, 0x65, 0x6E, 0x41, 0x42]); // len("en"), "en", "AB"
  });

  test('read-back decodes the text record that was written', () {
    final message = NdefMessage(records: [NfcWriter.textRecord('E9EBA0ED7C7C')]);
    // Round-trip through the on-tag byte format, like a real read-back.
    final decoded = NdefMessage.decode(message.encode());
    expect(NfcWriter.readText(decoded), 'E9EBA0ED7C7C');
    expect(NfcWriter.readText(null), isNull);
    expect(NfcWriter.readText(const NdefMessage(records: [])), isNull);
  });
}
