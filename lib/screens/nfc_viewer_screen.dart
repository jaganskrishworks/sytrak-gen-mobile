import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';

import '../services/ntag.dart';
import '../services/tag_info.dart';
import '../theme/app_colors.dart';

/// NFC Data Viewer: tap any tag and see everything on it. Read only - nothing is written,
/// no PC or station needed. Tap another tag at any time to read that one instead.
class NfcViewerScreen extends StatefulWidget {
  const NfcViewerScreen({super.key});

  @override
  State<NfcViewerScreen> createState() => _NfcViewerScreenState();
}

class _NfcViewerScreenState extends State<NfcViewerScreen> {
  TagInfo? _info;
  String _error = '';
  bool _reading = false;
  bool _sessionOpen = false;
  String _status = 'Starting NFC…';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    if (_sessionOpen) NfcManager.instance.stopSession().catchError((_) {});
    super.dispose();
  }

  Future<void> _start() async {
    final availability = await NfcManager.instance.checkAvailability();
    if (!mounted) return;
    if (availability != NfcAvailability.enabled) {
      setState(() => _status = availability == NfcAvailability.disabled
          ? 'NFC is turned off - enable it in the phone settings'
          : 'This phone has no NFC');
      return;
    }
    _sessionOpen = true;
    await NfcManager.instance.startSession(pollingOptions: {NfcPollingOption.iso14443}, onDiscovered: _onTag);
    if (mounted) setState(() => _status = 'Hold a tag to the back of the phone');
  }

  Future<void> _onTag(NfcTag tag) async {
    if (_reading) return;
    final io = AndroidNtagTransport.from(tag);
    if (io == null) {
      if (mounted) setState(() => _error = 'This tag is not an NFC-A tag (or this is an iPhone) - the viewer reads NTAG / Type 2 tags');
      return;
    }
    setState(() {
      _reading = true;
      _error = '';
    });
    try {
      final info = await readTagInfo(io);
      if (mounted) setState(() => _info = info);
    } on NtagException catch (e) {
      if (mounted) setState(() => _error = 'Could not read the tag (${e.message}) - hold it still and tap again');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('NFC Data Viewer')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _ScanBanner(status: _status, reading: _reading, hasData: info != null),
          if (_error.isNotEmpty) ...[const SizedBox(height: 12), _Notice(text: _error, color: AppColors.error, soft: AppColors.errorSoft)],
          if (info != null) ...[
            const SizedBox(height: 16),
            _SummaryCard(info: info),
            const SizedBox(height: 12),
            _tagCard(info),
            const SizedBox(height: 12),
            _stickerCard(info),
            const SizedBox(height: 12),
            _protectionCard(info),
            const SizedBox(height: 12),
            _recordsCard(info),
            const SizedBox(height: 12),
            _MemoryCard(info: info),
          ],
        ],
      ),
    );
  }

  Widget _tagCard(TagInfo i) => _Section(icon: Icons.nfc_rounded, title: 'Tag', rows: [
        _Row('UID', i.uid, mono: true, ok: i.uidFixed, note: i.uidFixed ? '7-byte fixed UID' : 'not a 7-byte fixed UID'),
        _Row('Chip', i.chip ?? 'Unknown (not NTAG213/215/216)', ok: i.chip != null),
        if (i.memory != null) _Row('User memory', '${i.memory} bytes (pages 4-${3 + i.memory! ~/ 4})'),
        _Row('GET_VERSION', i.version.isEmpty ? '— (not supported)' : _hex(i.version), mono: true),
        if (i.cc != null) _Row('Capability container', _hex(i.cc!), mono: true, ok: i.cc![0] == 0xE1,
            note: i.cc![0] == 0xE1 ? 'NDEF formatted' : 'not NDEF formatted'),
        _Row('Pages read', '${i.pageCount}'),
      ]);

  Widget _stickerCard(TagInfo i) {
    final sig = i.sigRecord;
    return _Section(icon: Icons.verified_user_outlined, title: 'SyTrak sticker data', rows: [
      _Row('MAC', i.mac ?? (i.macRecord?.text != null ? '"${i.macRecord!.text}" (not a MAC)' : 'missing'),
          mono: true, big: i.mac != null, ok: i.mac != null),
      _Row('Signature record', sig == null ? 'missing' : (i.sigWellFormed ? 'present, 49 B' : 'malformed (${sig.payload.length} B)'),
          ok: i.sigWellFormed),
      if (i.sigVersion != null) _Row('Format version', '${i.sigVersion}', ok: i.sigVersion == 1),
      if (i.keyId != null) _Row('Key ID', '${i.keyId}'),
      if (i.sigR != null) _Row('Signature r', _hex(i.sigR!, sep: ''), mono: true),
      if (i.sigS != null) _Row('Signature s', _hex(i.sigS!, sep: ''), mono: true),
      if (i.signedText != null) _Row('Signed text', i.signedText!, mono: true),
      const _Row('Signature valid?', 'Checked on the PC (Verification 2): it needs the trusted key', note: 'not checked on the phone'),
    ]);
  }

  Widget _protectionCard(TagInfo i) => _Section(icon: Icons.lock_outline_rounded, title: 'Password & lock', rows: [
        _Row('Password', 'Cannot be read from a tag: PWD / PACK always read back as 00',
            note: 'check it on the PC (Verification 2) or see it in the PC\'s admin view'),
        if (i.passwordProtected != null)
          _Row('Write protected', i.passwordProtected! ? 'Yes - pages ${i.auth0} and up need the password' : 'No - tag is open',
              warn: !i.passwordProtected!),
        if (i.auth0 != null) _Row('AUTH0', '${_byte(i.auth0!)}  (${i.auth0! <= i.cfg0! + 3 ? 'protection from page ${i.auth0}' : 'no protection'})', mono: true),
        if (i.access != null)
          _Row('ACCESS', '${_byte(i.access!)}  ·  reads need password: ${i.readProtected! ? 'yes' : 'no'}  ·  '
              'config frozen (CFGLCK): ${i.configLocked! ? 'YES' : 'no'}  ·  attempt limit: ${i.authLimit == 0 ? 'none' : i.authLimit}',
              ok: !i.configLocked!),
        _Row('Lock bits', i.hasLockBits ? 'SET - some pages are permanently read-only' : 'none (no page permanently locked)',
            ok: !i.hasLockBits),
        if (i.cfg0Bytes != null) _Row('CFG0 · CFG1', '${_hex(i.cfg0Bytes!)}  ·  ${_hex(i.cfg1Bytes!)}', mono: true),
      ]);

  Widget _recordsCard(TagInfo i) => _Section(
        icon: Icons.list_alt_rounded,
        title: 'NDEF records (${i.records.length})',
        rows: [
          if (i.records.isEmpty) _Row('Records', i.ndefProblem.isEmpty ? 'none' : i.ndefProblem, ok: false),
          for (final (n, r) in i.records.indexed)
            _Row('Record ${n + 1}', [
              '${r.tnfName} · type "${r.typeText}" · ${r.payload.length} B',
              if (r.text != null) 'Text (${r.language}): ${r.text}' else _hex(r.payload, sep: ''),
            ].join('\n'), mono: r.text == null),
        ],
      );

  static String _byte(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
  static String _hex(Uint8List b, {String sep = ' '}) => b.map(_byte).join(sep);
}

class _ScanBanner extends StatelessWidget {
  const _ScanBanner({required this.status, required this.reading, required this.hasData});

  final String status;
  final bool reading;
  final bool hasData;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(gradient: AppColors.primaryGradient, borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: reading
                  ? const CircularProgressIndicator(strokeWidth: 4, color: AppColors.onPrimary)
                  : const Icon(Icons.contactless_rounded, color: AppColors.onPrimary, size: 40),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(reading ? 'Reading… keep the tag still' : hasData ? 'Tap another tag to read it' : status,
                      style: const TextStyle(color: AppColors.onPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text('Read only · nothing is written · no PC needed',
                      style: TextStyle(color: AppColors.onPrimary.withValues(alpha: 0.8), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.info});

  final TagInfo info;

  @override
  Widget build(BuildContext context) {
    final i = info;
    final (IconData icon, Color color, Color soft, String title, String detail) = i.isSyTrakSticker
        ? (Icons.verified_rounded, AppColors.success, AppColors.successSoft, 'SyTrak sticker',
            'MAC ${i.mac ?? '?'} · signature key ${i.keyId ?? '?'} · ${i.passwordProtected == true ? 'locked' : 'not locked'}')
        : i.records.isEmpty
            ? (Icons.crop_square_rounded, AppColors.neutral, AppColors.neutralSoft, 'Empty tag', i.ndefProblem)
            : (Icons.info_rounded, AppColors.warning, AppColors.warningSoft, 'Not a SyTrak sticker',
                i.mac != null ? 'MAC ${i.mac} but no signature record' : '${i.records.length} other NDEF record(s)');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: color)),
                if (detail.isNotEmpty) Text(detail, style: const TextStyle(color: AppColors.textSecondary)),
                Text('UID ${i.uid}${i.chip != null ? ' · ${i.chip}' : ''}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row {
  const _Row(this.label, this.value, {this.mono = false, this.big = false, this.ok, this.warn = false, this.note = ''});

  final String label;
  final String value;
  final bool mono;
  final bool big;
  final bool? ok; // null = no mark
  final bool warn;
  final String note;
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.rows});

  final IconData icon;
  final String title;
  final List<_Row> rows;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              ]),
              const Divider(height: 20),
              for (final r in rows) _RowView(row: r),
            ],
          ),
        ),
      );
}

class _RowView extends StatelessWidget {
  const _RowView({required this.row});

  final _Row row;

  @override
  Widget build(BuildContext context) {
    final r = row;
    final (IconData? icon, Color color) = r.ok == true
        ? (Icons.check_circle_rounded, AppColors.success)
        : r.ok == false
            ? (Icons.cancel_rounded, AppColors.error)
            : r.warn
                ? (Icons.info_rounded, AppColors.warning)
                : (null, AppColors.textPrimary);
    return InkWell(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: r.value));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r.label} copied')));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              child: Text(r.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.value,
                      style: TextStyle(
                        fontSize: r.big ? 20 : 14,
                        fontWeight: r.big ? FontWeight.w800 : FontWeight.w500,
                        fontFamily: r.mono ? 'monospace' : null,
                        color: r.ok == false ? AppColors.error : AppColors.textPrimary,
                      )),
                  if (r.note.isNotEmpty) Text(r.note, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ],
              ),
            ),
            if (icon != null) ...[const SizedBox(width: 6), Icon(icon, size: 18, color: color)],
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color, required this.soft});

  final String text;
  final Color color;
  final Color soft;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      );
}

/// Every page, hex + ASCII, with what each page is. Collapsed by default.
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.info});

  final TagInfo info;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: const Icon(Icons.memory_rounded, color: AppColors.primary),
          title: Text('Memory - all ${info.pageCount} pages', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          subtitle: const Text('Hex + text, long-press to copy everything', style: TextStyle(fontSize: 12)),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            InkWell(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: info.pageLines().map((l) => '${l.$1}  ${l.$2}  ${l.$3}').join('\n')));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Memory copied')));
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(10)),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (page, bytes, name) in info.pageLines())
                        Text.rich(TextSpan(children: [
                          TextSpan(text: '$page  ', style: const TextStyle(color: AppColors.textMuted)),
                          TextSpan(text: bytes),
                          if (name.isNotEmpty) TextSpan(text: '  $name', style: const TextStyle(color: AppColors.primary)),
                        ]), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
