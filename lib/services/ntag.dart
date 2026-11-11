import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

/// NTAG213/215/216 with raw commands (nfc_sticker_v1.md §6):
///   GET_VERSION 60 · READ 30 pg (16 B) · WRITE A2 pg d0..d3 · PWD_AUTH 1B p0..p3
/// The steps follow sytrak_gen/src/sytrak_gen/core/ntag_sim.py (PhoneDriver), which the PC tests run.
/// The phone never decides whether a sticker is good: it reports the raw pages and the PC judges.

const _getVersion = 0x60, _read = 0x30, _write = 0xA2, _pwdAuth = 0x1B;
const _maxTries = 3;
const ndefStartPage = 4;

class NtagException implements Exception {
  NtagException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// GET_VERSION byte 6 -> (name, CFG0 page)
const chips = {0x0F: ('NTAG213', 41), 0x11: ('NTAG215', 131), 0x13: ('NTAG216', 227)};

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// Raw access to one tag. A refused command and an RF dropout both throw [NtagException].
abstract class NtagTransport {
  Uint8List get uid;
  Future<Uint8List> transceive(List<int> command);

  /// Field reset / re-select (drops PWD_AUTH and clears a HALT after a refused command).
  Future<void> reconnect();
}

/// Android: NfcA, re-selected by switching to MifareUltralight and back (the plugin then
/// closes one technology and connects the other, which re-activates the tag).
class AndroidNtagTransport implements NtagTransport {
  AndroidNtagTransport._(this._a, this._mu, this.uid);

  final NfcAAndroid _a;
  final MifareUltralightAndroid? _mu;
  bool _useMu = false;
  @override
  final Uint8List uid;

  /// Null when the tag is not NFC-A (or this is not Android).
  static AndroidNtagTransport? from(NfcTag tag) {
    if (!Platform.isAndroid) return null;
    final a = NfcAAndroid.from(tag);
    if (a == null) return null;
    return AndroidNtagTransport._(a, MifareUltralightAndroid.from(tag), a.tag.id);
  }

  @override
  Future<Uint8List> transceive(List<int> command) async {
    final bytes = Uint8List.fromList(command);
    try {
      final mu = _mu;
      return _useMu && mu != null ? await mu.transceive(bytes) : await _a.transceive(bytes);
    } on PlatformException catch (e) {
      throw NtagException(e.message ?? e.code);
    }
  }

  @override
  Future<void> reconnect() async {
    if (_mu == null) throw NtagException('This phone cannot re-select the tag - lift it and tap again');
    _useMu = !_useMu;
    await Future<void>.delayed(const Duration(milliseconds: 20)); // ~20 ms after a field reset (§8)
    try {
      await transceive([_read, 0]); // connects the other technology now
    } on NtagException {
      // the next command will tell
    }
  }
}

typedef StepCallback = void Function(String step, bool ok, String detail);

/// What the phone does with a tag for one job. Results are the evt/nfc_done payload.
class NtagDriver {
  NtagDriver(this.io, {this.onStep});

  final NtagTransport io;
  final StepCallback? onStep;
  final steps = <Map<String, Object>>[];
  Uint8List version = Uint8List(0);
  Uint8List pages = Uint8List(0);
  int? cfg0;
  String chipName = '';

  int get lastPage => cfg0! + 3;
  String get uidHex => hex(io.uid);

  void _step(String step, bool ok, [String detail = '']) {
    steps.add({'step': step, 'ok': ok, 'detail': detail});
    onStep?.call(step, ok, detail);
  }

  Future<Uint8List> _readAll() async {
    final out = BytesBuilder();
    for (var page = 0; page <= lastPage; page += 4) {
      final data = await io.transceive([_read, page]);
      if (data.length < 16) throw NtagException('Short read at page $page');
      out.add(data);
    }
    return Uint8List.fromList(out.takeBytes().sublist(0, (lastPage + 1) * 4));
  }

  Future<bool> _auth(List<int> pwd, List<int> pack) async {
    try {
      final answer = await io.transceive([_pwdAuth, ...pwd]);
      return answer.length >= 2 && answer[0] == pack[0] && answer[1] == pack[1];
    } on NtagException {
      return false; // refused: the tag is halted until reconnect()
    }
  }

  /// Write page by page; on a dropout reconnect (+ PWD_AUTH if protected) and resume from that page.
  Future<void> _writePages(int start, List<int> data, List<int> pwd, List<int> pack, bool protected) async {
    var pos = 0, failures = 0;
    while (pos < data.length) {
      final page = start + pos ~/ 4;
      try {
        final ack = await io.transceive([_write, page, ...data.sublist(pos, pos + 4)]);
        // Some phones hand back a NAK (4-bit, != 0x0A) instead of throwing.
        if (ack.isNotEmpty && (ack[0] & 0x0F) != 0x0A) throw NtagException('write refused (NAK ${ack[0]})');
        pos += 4;
      } on NtagException catch (e) {
        failures++;
        if (failures >= _maxTries) rethrow;
        _step('write', true, 'page $page: ${e.message} - reconnect and retry from page $page');
        await io.reconnect();
        if (protected && !await _auth(pwd, pack)) throw NtagException('PWD_AUTH refused after reconnect');
      }
    }
  }

  /// First touch: UID, GET_VERSION, every page. Sent to the PC as evt/nfc_tag.
  Future<Map<String, Object>> inspect() async {
    version = await io.transceive([_getVersion]);
    final chip = version.length >= 8 ? chips[version[6]] : null;
    if (chip != null) {
      chipName = chip.$1;
      cfg0 = chip.$2;
      pages = await _readAll();
    }
    _step('tag', true, 'UID $uidHex, ${chip?.$1 ?? 'unknown chip'}');
    return {'uid': uidHex, 'version': hex(version), 'pages': hex(pages)};
  }

  Future<Map<String, Object>> _done(
      {required bool ok, String step = '', String error = '', String password = 'not checked', bool pwdWritten = false, bool locked = false}) async {
    var finalPages = pages;
    if (cfg0 != null) {
      try {
        finalPages = await _readAll();
      } on NtagException {
        try {
          await io.reconnect(); // e.g. halted after a refused PWD_AUTH
          finalPages = await _readAll();
        } on NtagException catch (e) {
          _step('final read', false, e.message);
        }
      }
    }
    return {
      'ok': ok, 'step': step, 'error': error, 'uid': uidHex, 'version': hex(version), 'pages': hex(finalPages),
      'password': password, 'pwd_written': pwdWritten, 'locked': locked, 'steps': steps,
    };
  }

  /// Verification 1: write the signed NDEF, read it back, set + check the password. No lock (see below).
  Future<Map<String, Object>> writeJob(int startPage, Uint8List ndef, Uint8List pwd, Uint8List pack, {bool lock = false}) async {
    try {
      if (cfg0 == null) await inspect();
      if (cfg0 == null) return await _done(ok: false, step: 'check', error: 'Not an NTAG213/215/216');
      final c = cfg0! * 4;
      final cfg0Bytes = pages.sublist(c, c + 4), cfg1Bytes = pages.sublist(c + 4, c + 8);
      if (cfg1Bytes[0] & 0x40 != 0) return await _done(ok: false, step: 'check', error: 'CFGLCK set - configuration frozen, use another tag');
      final protected = cfg0Bytes[3] <= lastPage;
      if (protected && !await _auth(pwd, pack)) return await _done(ok: false, step: 'pwd_auth', error: 'Tag is locked with another password');

      await _writePages(startPage, ndef, pwd, pack, protected);
      _step('write', true, '${ndef.length ~/ 4} pages from page $startPage');
      var identical = false;
      for (var attempt = 0; attempt < _maxTries && !identical; attempt++) {
        final all = await _readAll();
        final back = all.sublist(startPage * 4, startPage * 4 + ndef.length);
        var bad = -1;
        for (var i = 0; i < ndef.length; i++) {
          if (back[i] != ndef[i]) {
            bad = i - i % 4;
            break;
          }
        }
        if (bad < 0) {
          identical = true;
          _step('readback', true, '${ndef.length} B identical');
        } else {
          _step('readback', false, 'page ${startPage + bad ~/ 4} differs - writing again');
          await _writePages(startPage + bad ~/ 4, ndef.sublist(bad), pwd, pack, protected);
        }
      }
      if (!identical) return await _done(ok: false, step: 'readback', error: 'Read-back still differs after $_maxTries tries');

      // Password: PWD page CFG0+2, PACK page CFG0+3 (PACK0 PACK1 00 00). The tag stays open (AUTH0 untouched).
      await _writePages(cfg0! + 2, [...pwd, ...pack, 0, 0], pwd, pack, protected);
      _step('password', true, 'PWD and PACK written');
      await io.reconnect();
      final validated = await _auth(pwd, pack);
      _step('pwd_auth', validated, validated ? 'PACK matches' : 'PWD_AUTH refused / wrong PACK');

      // ---- Lock (spec §6 steps 6-8), when the PC asks for it. Never lock bits, never CFGLCK. ----
      var locked = false;
      if (!lock) {
        _step('lock', true, 'skipped - locking is switched off on the PC');
      } else if (!validated) {
        _step('lock', false, 'not locked - the password check failed'); // never lock with an unproven password
      } else {
        // 6. ACCESS: keep CFG1 bytes 1-3, clear PROT (reads stay open), CFGLCK and AUTHLIM (unlimited tries).
        await _writePages(cfg0! + 1, [cfg1Bytes[0] & 0x38, ...cfg1Bytes.sublist(1, 4)], pwd, pack, true);
        // 7. AUTH0 = 02 - always the LAST write: pages 2.. then need the password to write.
        await _writePages(cfg0!, [...cfg0Bytes.sublist(0, 3), 0x02], pwd, pack, true);
        // 8. Read CFG0 back: AUTH0 must be 02.
        final check = await io.transceive([_read, cfg0!]);
        locked = check.length >= 4 && check[3] == 0x02;
        _step('lock', locked, locked ? 'AUTH0 = 02: locked, reads stay open' : 'AUTH0 read back is not 02');
      }

      // ok = every step ran; the PC judges the result (password / lock state show up in its checks).
      return await _done(ok: true, password: validated ? 'validated' : 'failed', pwdWritten: true, locked: locked);
    } on NtagException catch (e) {
      return await _done(ok: false, step: 'write', error: '${e.message} - hold the tag still and try again');
    }
  }

  /// Verification 2: read only - check the password with PWD_AUTH, read every page.
  Future<Map<String, Object>> verifyJob(Uint8List pwd, Uint8List pack) async {
    try {
      if (cfg0 == null) await inspect();
      final validated = await _auth(pwd, pack);
      _step('pwd_auth', validated, validated ? 'PACK matches' : 'PWD_AUTH refused / wrong PACK');
      return await _done(ok: true, password: validated ? 'validated' : 'failed');
    } on NtagException catch (e) {
      return await _done(ok: false, step: 'read', error: e.message);
    }
  }
}
