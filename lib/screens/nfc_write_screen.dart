import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';

import '../models.dart';
import '../services/nfc_writer.dart';
import '../services/station_client.dart';
import '../theme/app_colors.dart';

enum _Phase { ready, writing, done, failed }

/// "WRITE TO NFC" request from the station. Pops with true once written.
class NfcWriteScreen extends StatefulWidget {
  const NfcWriteScreen({super.key, required this.client, required this.request});

  final StationClient client;
  final NfcWriteRequest request;

  @override
  State<NfcWriteScreen> createState() => _NfcWriteScreenState();
}

class _NfcWriteScreenState extends State<NfcWriteScreen> {
  _Phase _phase = _Phase.ready;
  String _error = '';
  bool _reported = false;

  String _readBack = '';

  void _report({required bool ok, String error = '', String? readBack}) {
    if (_reported) return;
    _reported = true;
    widget.client.sendNfcResult(widget.request.seq, ok: ok, error: error, readBack: readBack);
  }

  Future<void> _write() async {
    final availability = await NfcWriter.availability();
    if (availability != NfcAvailability.enabled) {
      setState(() {
        _phase = _Phase.failed;
        _error = availability == NfcAvailability.disabled ? 'NFC is turned off - enable it in phone settings' : 'This phone has no NFC';
      });
      return;
    }
    setState(() => _phase = _Phase.writing);
    try {
      final readBack = await NfcWriter.writeText(widget.request.data);
      _report(ok: true, readBack: readBack);
      if (mounted) {
        setState(() {
          _readBack = readBack;
          _phase = _Phase.done;
        });
      }
    } on NfcWriteException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _cancelWrite() async {
    await NfcWriter.cancel();
    if (mounted) setState(() => _phase = _Phase.ready);
  }

  void _close() {
    if (_phase != _Phase.done) {
      if (_phase == _Phase.writing) NfcWriter.cancel();
      _report(ok: false, error: _error.isEmpty ? 'Cancelled on phone' : _error);
    }
    Navigator.of(context).pop(_phase == _Phase.done);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Write to NFC'), leading: IconButton(icon: const Icon(Icons.close), onPressed: _close)),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.nfc_rounded, color: AppColors.primary),
                          const SizedBox(width: 8),
                          Text('WRITE TO NFC',
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: AppColors.primary, letterSpacing: 0.6)),
                        ],
                      ),
                      const Divider(height: 24),
                      Text('MAC  ${r.mac}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFamily: 'monospace', color: AppColors.textPrimary)),
                      if (r.seq.isNotEmpty) Text('SEQ  ${r.seq}', style: const TextStyle(fontSize: 18, color: AppColors.textSecondary)),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(10)),
                        child: Text(r.data, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              _phaseView(theme),
              const Spacer(),
              ..._actions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phaseView(ThemeData theme) {
    Widget big(IconData icon, Color color, Color soft, String text) => Column(
          children: [
            Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(color: soft, shape: BoxShape.circle),
              child: Icon(icon, size: 72, color: color),
            ),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: color)),
          ],
        );
    return switch (_phase) {
      _Phase.ready =>
        big(Icons.nfc_rounded, AppColors.primary, AppColors.primarySoft, 'Press WRITE, then hold the tag\nto the back of the phone'),
      _Phase.writing => Column(children: [
          const SizedBox(width: 72, height: 72, child: CircularProgressIndicator(strokeWidth: 6)),
          const SizedBox(height: 24),
          Text('Hold the NFC tag still on the phone…\nwriting, then reading it back to verify',
              textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(color: AppColors.textSecondary)),
        ]),
      _Phase.done => big(Icons.check_circle_rounded, AppColors.success, AppColors.successSoft,
          'Tag written and verified\nRead back: $_readBack\nThe PC has been notified'),
      _Phase.failed => big(Icons.error_rounded, AppColors.error, AppColors.errorSoft, _error),
    };
  }

  List<Widget> _actions() => switch (_phase) {
        _Phase.ready => [FilledButton.icon(onPressed: _write, icon: const Icon(Icons.edit_note), label: const Text('WRITE'))],
        _Phase.writing => [OutlinedButton(onPressed: _cancelWrite, child: const Text('Cancel'))],
        _Phase.done => [FilledButton(onPressed: _close, child: const Text('Done'))],
        _Phase.failed => [
            FilledButton.icon(onPressed: _write, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _close, child: const Text('Give up - report failure to PC')),
          ],
      };
}
