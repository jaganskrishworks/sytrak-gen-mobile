import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';

import '../models.dart';
import '../services/ntag.dart';
import '../services/station_client.dart';
import '../theme/app_colors.dart';

enum _Phase { starting, tap, working, waitingVerdict, verdict, refused, failed, cancelled }

/// One NFC job started by the PC. The phone only moves bytes: it reads the tag, sends it to the PC,
/// does what the PC answers (write + password, or a read-only password check) and reports back.
/// The PC judges the tag and sends its verdict, which is shown here with every check.
class NfcJobScreen extends StatefulWidget {
  const NfcJobScreen({super.key, required this.client, required this.job});

  final StationClient client;
  final NfcJob job;

  @override
  State<NfcJobScreen> createState() => _NfcJobScreenState();
}

class _NfcJobScreenState extends State<NfcJobScreen> {
  _Phase _phase = _Phase.starting;
  String _message = '';
  String _uid = '';
  bool _busy = false;
  bool _doneSent = false;
  bool _sessionOpen = false;
  NfcVerdict? _verdict;
  final _steps = <(String, bool, String)>[];
  late final StreamSubscription<NfcVerdict> _verdictSub;
  late final StreamSubscription<String> _cancelSub;

  NfcJob get job => widget.job;
  StationClient get client => widget.client;

  static const _stepNames = {
    'tag': 'Tag detected', 'write': 'Write', 'readback': 'Read back', 'password': 'Password set',
    'pwd_auth': 'Password check', 'lock': 'Lock', 'read': 'Read', 'final read': 'Final read',
  };

  @override
  void initState() {
    super.initState();
    _verdictSub = client.nfcVerdicts.where((v) => v.jobId == job.jobId).listen((v) {
      if (!mounted) return;
      setState(() {
        _verdict = v;
        _phase = _Phase.verdict;
      });
    });
    _cancelSub = client.nfcCancels.listen((value) {
      final parts = value.split('|');
      if (parts.first != job.jobId || _doneSent) return;
      _stopSession();
      _set(_Phase.cancelled, parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'Cancelled on the PC');
    });
    _start();
  }

  @override
  void dispose() {
    _verdictSub.cancel();
    _cancelSub.cancel();
    _stopSession();
    super.dispose();
  }

  void _set(_Phase phase, [String message = '']) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _message = message;
    });
  }

  Future<void> _start() async {
    final availability = await NfcManager.instance.checkAvailability();
    if (availability != NfcAvailability.enabled) {
      final why = availability == NfcAvailability.disabled ? 'NFC is turned off - enable it in the phone settings' : 'This phone has no NFC';
      _set(_Phase.failed, why);
      await _reportFailure('phone', why);
      return;
    }
    _sessionOpen = true;
    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      alertMessageIos: 'Hold the NFC tag near the phone',
      onDiscovered: _onTag,
    );
    _set(_Phase.tap);
  }

  void _stopSession() {
    if (!_sessionOpen) return;
    _sessionOpen = false;
    NfcManager.instance.stopSession().catchError((_) {});
  }

  void _addStep(String step, bool ok, String detail) {
    client.sendNfcProgress(job.jobId, step, ok, detail);
    if (mounted) setState(() => _steps.add((step, ok, detail)));
  }

  Future<void> _onTag(NfcTag tag) async {
    if (_busy || _doneSent || _phase == _Phase.cancelled) return; // one tag at a time
    _busy = true;
    try {
      final io = AndroidNtagTransport.from(tag);
      if (io == null) {
        _set(_Phase.refused, 'This tag cannot be used (not NFC-A), or this is an iPhone - signed stickers need an Android phone');
        return;
      }
      _steps.clear();
      _uid = hex(io.uid);
      _set(_Phase.working, 'Reading the tag…');
      final driver = NtagDriver(io, onStep: _addStep);
      Map<String, Object> first;
      try {
        first = await driver.inspect();
      } on NtagException catch (e) {
        _set(_Phase.refused, 'Could not read the tag (${e.message}) - hold it still and tap again');
        return;
      }
      _set(_Phase.working, 'Waiting for the PC…');
      final reply = await client.requestJobReply(job.jobId, first);
      if (reply == null) {
        _set(_Phase.refused, 'No answer from the PC - check the Wi-Fi, then tap the tag again');
        return;
      }
      try {
        final problem = reply.problem(job);
        if (problem != null) {
          _set(_Phase.refused, problem);
          return;
        }
        _set(_Phase.working, job.isWrite ? 'Writing the signed sticker - keep the tag still…' : 'Checking the tag - keep it still…');
        final result = job.isWrite
            ? await driver.writeJob(reply.writePage!, reply.writeData!, reply.pwd!, reply.pack!, lock: reply.lock)
            : await driver.verifyJob(reply.pwd!, reply.pack!);
        _stopSession();
        _doneSent = true;
        _set(_Phase.waitingVerdict, result['ok'] == true ? 'Done - the PC is checking the tag…' : '${result['error']}');
        if (!await client.sendNfcDone(job.jobId, result)) {
          _set(_Phase.failed, 'Could not send the result to the PC - check the connection');
        }
      } finally {
        reply.wipe(); // PWD/PACK never outlive the job
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _reportFailure(String step, String error) async {
    if (_doneSent) return;
    _doneSent = true;
    await client.sendNfcDone(job.jobId, {'ok': false, 'step': step, 'error': error, 'uid': _uid, 'version': '', 'pages': ''});
  }

  Future<void> _close() async {
    _stopSession();
    if (!_doneSent && _phase != _Phase.cancelled) {
      await _reportFailure('phone', 'Closed on the phone before the tag was finished');
    }
    if (mounted) Navigator.of(context).pop(_verdict?.ok == true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(job.isWrite ? 'Write NFC sticker' : 'Verify NFC sticker'),
          leading: IconButton(icon: const Icon(Icons.close), onPressed: _close),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _JobCard(job: job, uid: _uid),
            const SizedBox(height: 16),
            _phaseCard(),
            if (_verdict != null) ...[const SizedBox(height: 16), _VerdictCard(verdict: _verdict!)],
            if (_steps.isNotEmpty) ...[const SizedBox(height: 16), _stepsCard()],
            const SizedBox(height: 20),
            if (_phase == _Phase.verdict || _phase == _Phase.failed || _phase == _Phase.cancelled)
              FilledButton(onPressed: _close, child: const Text('Done'))
            else
              OutlinedButton(onPressed: _close, child: const Text('Cancel')),
            if (_phase == _Phase.verdict && _verdict?.ok == false) ...[
              const SizedBox(height: 8),
              const Text('To try again, start it again on the PC.', textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _phaseCard() {
    final (IconData icon, Color color, Color soft, String text) = switch (_phase) {
      _Phase.starting => (Icons.nfc_rounded, AppColors.primary, AppColors.primarySoft, 'Starting NFC…'),
      _Phase.tap => (Icons.nfc_rounded, AppColors.primary, AppColors.primarySoft,
          'Hold the NFC tag to the back of the phone\nand keep it still until it is done'),
      _Phase.working => (Icons.sync_rounded, AppColors.primary, AppColors.primarySoft, _message),
      _Phase.waitingVerdict => (Icons.hourglass_top_rounded, AppColors.primary, AppColors.primarySoft, _message),
      _Phase.verdict => _verdict!.ok
          ? (Icons.verified_rounded, AppColors.success, AppColors.successSoft, _verdict!.headline)
          : (Icons.cancel_rounded, AppColors.error, AppColors.errorSoft, '${_verdict!.headline}\n${_verdict!.error}'),
      _Phase.refused => (Icons.block_rounded, AppColors.warning, AppColors.warningSoft, '$_message\n\nTap a tag to try again'),
      _Phase.failed => (Icons.error_rounded, AppColors.error, AppColors.errorSoft, _message),
      _Phase.cancelled => (Icons.cancel_outlined, AppColors.neutral, AppColors.neutralSoft, 'Cancelled: $_message'),
    };
    final spinning = _phase == _Phase.working || _phase == _Phase.waitingVerdict;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: spinning ? CircularProgressIndicator(strokeWidth: 6, color: color) : Icon(icon, size: 64, color: color),
          ),
          const SizedBox(height: 14),
          Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _stepsCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Steps on the tag', style: TextStyle(fontWeight: FontWeight.w700)),
              const Divider(height: 20),
              for (final (step, ok, detail) in _steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(ok ? Icons.check_rounded : Icons.close_rounded, size: 18, color: ok ? AppColors.success : AppColors.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${_stepNames[step] ?? step}${detail.isEmpty ? '' : ': $detail'}',
                            style: const TextStyle(color: AppColors.textSecondary)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job, required this.uid});

  final NfcJob job;
  final String uid;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(job.isWrite ? Icons.edit_note_rounded : Icons.fact_check_rounded, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(job.title.toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.primary, letterSpacing: 0.5)),
                  ),
                ],
              ),
              const Divider(height: 24),
              Text('MAC  ${job.mac}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFamily: 'monospace', color: AppColors.textPrimary)),
              if (job.seq.isNotEmpty) Text('SEQ  ${job.seq}', style: const TextStyle(fontSize: 17, color: AppColors.textSecondary)),
              if (uid.isNotEmpty) Text('Tag  $uid', style: const TextStyle(fontFamily: 'monospace', color: AppColors.textSecondary)),
              const SizedBox(height: 6),
              Text(job.isWrite ? 'The PC signs the sticker and sets its password, then the tag is locked against writing (when locking is on).' : 'Nothing is written to the tag.',
                  style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
            ],
          ),
        ),
      );
}

/// Every check the PC made: signature present / valid, MAC present / = device, password, locked…
class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.verdict});

  final NfcVerdict verdict;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(verdict.ok ? Icons.verified_rounded : Icons.gpp_bad_rounded, color: verdict.ok ? AppColors.success : AppColors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(verdict.ok ? 'Verified by the PC' : 'Not verified',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: verdict.ok ? AppColors.success : AppColors.error)),
                  ),
                ],
              ),
              const Divider(height: 20),
              for (final c in verdict.checks) _CheckLine(check: c),
              if (verdict.sheet.isNotEmpty) ...[
                const Divider(height: 20),
                Row(
                  children: [
                    const Icon(Icons.table_chart_outlined, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(verdict.sheet, style: const TextStyle(color: AppColors.textSecondary))),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.check});

  final NfcCheck check;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (check.state) {
      'ok' => (Icons.check_circle_rounded, AppColors.success),
      'fail' => (Icons.cancel_rounded, AppColors.error),
      'info' => (Icons.info_rounded, AppColors.primary),
      _ => (Icons.remove_circle_outline, AppColors.neutral),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(check.title, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                if (check.detail.isNotEmpty)
                  Text(check.detail, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
