import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

class NfcWriteException implements Exception {
  NfcWriteException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Writes a single NDEF text record to the next tag that is tapped.
class NfcWriter {
  static Future<NfcAvailability> availability() => NfcManager.instance.checkAvailability();

  /// NDEF Well-Known "T" (text) record, UTF-8, language "en".
  static NdefRecord textRecord(String text, {String lang = 'en'}) {
    final langBytes = ascii.encode(lang);
    return NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList([0x54]),
      identifier: Uint8List(0),
      payload: Uint8List.fromList([langBytes.length, ...langBytes, ...utf8.encode(text)]),
    );
  }

  static Future<void> cancel() => NfcManager.instance.stopSession(errorMessageIos: 'Cancelled');

  /// Reads the next tag that is tapped and returns its NDEF text (nothing is written).
  /// Throws [NfcWriteException] if the tag has no NDEF text record or cannot be read.
  static Future<String> readTag() async {
    final completer = Completer<String>();

    void fail(String reason) {
      if (!completer.isCompleted) completer.completeError(NfcWriteException(reason));
      NfcManager.instance.stopSession(errorMessageIos: reason);
    }

    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
      alertMessageIos: 'Hold the NFC tag near the top of the iPhone',
      invalidateAfterFirstReadIos: false,
      onSessionErrorIos: (err) {
        if (!completer.isCompleted) completer.completeError(NfcWriteException(err.message));
      },
      onDiscovered: (tag) async {
        try {
          NdefMessage? message;
          if (Platform.isAndroid) {
            final ndef = NdefAndroid.from(tag);
            if (ndef == null) return fail('Tag is empty or not NDEF formatted');
            message = await ndef.getNdefMessage();
          } else {
            final ndef = NdefIos.from(tag);
            if (ndef == null) return fail('Tag is empty or not NDEF formatted');
            message = await ndef.readNdef();
          }
          final text = readText(message);
          if (text == null) return fail('No text found on the tag');
          await NfcManager.instance.stopSession(alertMessageIos: 'Tag read');
          if (!completer.isCompleted) completer.complete(text);
        } on Object catch (e) {
          fail('Read failed - keep the tag still and try again ($e)');
        }
      },
    );
    return completer.future;
  }

  /// Text of the first NDEF "T" record, or null if the message has none.
  static String? readText(NdefMessage? message) {
    for (final record in message?.records ?? const <NdefRecord>[]) {
      if (record.typeNameFormat != TypeNameFormat.wellKnown || record.type.length != 1 || record.type[0] != 0x54) continue;
      final payload = record.payload;
      if (payload.isEmpty) return '';
      final status = payload[0];
      final langLength = status & 0x3F;
      if (payload.length < 1 + langLength) return null;
      final body = payload.sublist(1 + langLength);
      final utf16 = status & 0x80 != 0;
      return utf16 ? String.fromCharCodes(_utf16be(body)) : utf8.decode(body, allowMalformed: true);
    }
    return null;
  }

  static Iterable<int> _utf16be(List<int> b) sync* {
    for (var i = 0; i + 1 < b.length; i += 2) {
      yield (b[i] << 8) | b[i + 1];
    }
  }

  /// Writes [text], then reads the tag back while it is still in range.
  ///
  /// Completes with the text read back (always equal to [text]); throws
  /// [NfcWriteException] if writing fails or the read-back does not match.
  static Future<String> writeText(String text) async {
    final completer = Completer<String>();
    final message = NdefMessage(records: [textRecord(text)]);

    void fail(String reason) {
      if (!completer.isCompleted) completer.completeError(NfcWriteException(reason));
      NfcManager.instance.stopSession(errorMessageIos: reason);
    }

    String verify(NdefMessage? readBack) {
      final got = readText(readBack);
      if (got == null) throw NfcWriteException('Verify failed: no text found on the tag after writing');
      if (got != text) throw NfcWriteException('Verify failed: tag reads "$got" instead of "$text"');
      return got;
    }

    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
      alertMessageIos: 'Hold the NFC tag near the top of the iPhone',
      invalidateAfterFirstReadIos: false,
      onSessionErrorIos: (err) {
        if (!completer.isCompleted) completer.completeError(NfcWriteException(err.message));
      },
      onDiscovered: (tag) async {
        try {
          String readBack;
          if (Platform.isAndroid) {
            var ndef = NdefAndroid.from(tag);
            if (ndef != null) {
              if (!ndef.isWritable) return fail('Tag is read-only');
              await ndef.writeNdefMessage(message);
            } else {
              final formatable = NdefFormatableAndroid.from(tag);
              if (formatable == null) return fail('Tag does not support NDEF');
              await formatable.format(message);
              ndef = NdefAndroid.from(tag);
              if (ndef == null) {
                return fail('New tag formatted - press Try again and tap it once more to verify');
              }
            }
            readBack = verify(await ndef.getNdefMessage());
            await NfcManager.instance.stopSession();
          } else {
            final ndef = NdefIos.from(tag);
            if (ndef == null) return fail('Tag does not support NDEF');
            final status = await ndef.queryNdefStatus();
            if (status.status == NdefStatusIos.notSupported) return fail('Tag does not support NDEF');
            if (status.status == NdefStatusIos.readOnly) return fail('Tag is read-only');
            await ndef.writeNdef(message);
            readBack = verify(await ndef.readNdef());
            await NfcManager.instance.stopSession(alertMessageIos: 'Tag written and verified');
          }
          if (!completer.isCompleted) completer.complete(readBack);
        } on NfcWriteException catch (e) {
          fail(e.message);
        } on Object catch (e) {
          fail('Write failed - keep the tag still and try again ($e)');
        }
      },
    );
    return completer.future;
  }
}
