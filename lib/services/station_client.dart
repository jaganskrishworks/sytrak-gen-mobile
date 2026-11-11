import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models.dart';

enum LinkState { disconnected, connecting, connected, paired, failed }

/// MQTT link to one station (see sytrak_gen/docs/MOBILE_PROTOCOL.md).
class StationClient extends ChangeNotifier {
  StationClient({required this.mobileId, required this.mobileName});

  final String mobileId;
  String mobileName;

  MqttServerClient? _client;
  StreamSubscription? _updates;
  Station? station;
  LinkState state = LinkState.disconnected;
  String? error;
  ScanAck? lastAck;

  /// Device the PC currently wants verified (expected MAC + SEQ); null = none yet.
  VerifyRequest? verifyRequest;

  /// PC's verdict on the last sticker sent.
  VerifyResult? verifyResult;

  /// NFC jobs - always started by the PC (cmd/nfc_job); the phone only handles the tag.
  final _nfcJobs = StreamController<NfcJob>.broadcast();
  final _nfcVerdicts = StreamController<NfcVerdict>.broadcast();
  final _nfcCancels = StreamController<String>.broadcast();
  final _replyWaiters = <String, Completer<NfcJobReply>>{};

  Stream<NfcJob> get nfcJobs => _nfcJobs.stream;
  Stream<NfcVerdict> get nfcVerdicts => _nfcVerdicts.stream;

  /// Job ids (with the reason after a '|') the PC cancelled.
  Stream<String> get nfcCancels => _nfcCancels.stream;
  bool get isPaired => state == LinkState.paired;

  String _topic(String suffix) => 'sytrak/${station!.id}/mobile/$mobileId/$suffix';

  void _set(LinkState s, {String? err}) {
    state = s;
    error = err;
    notifyListeners();
  }

  Future<bool> connect(Station target, {String password = ''}) async {
    await disconnect();
    station = target;
    lastAck = null;
    verifyRequest = null;
    verifyResult = null;
    _set(LinkState.connecting);

    final client = MqttServerClient.withPort(target.host, mobileId, target.port)
      ..setProtocolV311()
      ..keepAlivePeriod = 20
      ..connectTimeoutPeriod = 5000
      ..autoReconnect = true
      ..logging(on: false);
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(mobileId)
        .withWillTopic(_topic('status'))
        .withWillMessage('offline')
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .startClean();
    client.onDisconnected = _onDisconnected;
    client.onAutoReconnect = () => _set(LinkState.connecting);
    client.onAutoReconnected = _announce;
    _client = client;

    try {
      await client.connect(target.auth ? 'sytrak' : null, target.auth ? password : null);
    } on Exception catch (e) {
      _client = null;
      client.disconnect();
      final refused = client.connectionStatus?.returnCode == MqttConnectReturnCode.badUsernameOrPassword ||
          client.connectionStatus?.returnCode == MqttConnectReturnCode.notAuthorized;
      _set(LinkState.failed, err: refused ? 'Wrong station password' : 'Could not reach ${target.host}:${target.port} ($e)');
      return false;
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _client = null;
      _set(LinkState.failed, err: 'Connection refused (${client.connectionStatus?.returnCode})');
      return false;
    }
    _updates = client.updates?.listen(_onMessages);
    client.subscribe(_topic('cmd/#'), MqttQos.atLeastOnce);
    _announce();
    return true;
  }

  /// Tell the station who we are (also after every reconnect).
  void _announce() {
    _publish('status', 'online', retain: true);
    _publish('evt/hello', jsonEncode({'name': mobileName}));
    if (state != LinkState.paired) _set(LinkState.connected);
  }

  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    await _updates?.cancel();
    _updates = null;
    if (client != null) {
      client.autoReconnect = false;
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _publishOn(client, 'status', 'offline', retain: true);
      }
      client.disconnect();
    }
    if (state != LinkState.disconnected) _set(LinkState.disconnected);
  }

  void _onDisconnected() {
    if (_client == null) return; // we disconnected on purpose
    if (_client!.connectionStatus?.disconnectionOrigin == MqttDisconnectionOrigin.solicited) {
      _set(LinkState.disconnected);
    } else {
      _set(LinkState.connecting, err: 'Connection lost - reconnecting…');
    }
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final m in messages) {
      final msg = m.payload;
      if (msg is! MqttPublishMessage) continue;
      final name = m.topic.split('/').last;
      Map<String, dynamic> data;
      try {
        data = Map<String, dynamic>.from(jsonDecode(utf8.decode(msg.payload.message)) as Map);
      } on Object {
        continue;
      }
      switch (name) {
        case 'session':
          _set(data['state'] == 'paired' ? LinkState.paired : LinkState.connected);
        case 'scan_ack':
          lastAck = ScanAck(data['accepted'] == true, '${data['reason'] ?? ''}');
          notifyListeners();
        case 'verify_request':
          verifyRequest = VerifyRequest.fromJson(data);
          verifyResult = null;
          lastAck = null;
          notifyListeners();
        case 'verify_result':
          verifyResult = VerifyResult.fromJson(data);
          notifyListeners();
        case 'nfc_job':
          final job = NfcJob.fromJson(data);
          if (job.jobId.isNotEmpty) _nfcJobs.add(job);
        case 'nfc_job_reply':
          final reply = NfcJobReply.fromJson(data);
          final waiter = _replyWaiters.remove(reply.jobId);
          if (waiter != null && !waiter.isCompleted) {
            waiter.complete(reply);
          } else {
            reply.wipe(); // nobody is waiting (late resend answer)
          }
        case 'nfc_verdict':
          _nfcVerdicts.add(NfcVerdict.fromJson(data));
        case 'nfc_cancel':
          _nfcCancels.add('${data['job_id'] ?? ''}|${data['reason'] ?? ''}');
      }
    }
  }

  /// evt/nfc_tag, then wait for cmd/nfc_job_reply. The same data is resent up to [attempts] times
  /// (the PC answers a resend with the same reply). Null = no answer from the PC.
  Future<NfcJobReply?> requestJobReply(String jobId, Map<String, Object> tag,
      {int attempts = 3, Duration timeout = const Duration(seconds: 5)}) async {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final waiter = Completer<NfcJobReply>();
      _replyWaiters[jobId] = waiter;
      if (!_publish('evt/nfc_tag', jsonEncode({'job_id': jobId, 'attempt': attempt, ...tag}))) {
        await Future<void>.delayed(const Duration(seconds: 1)); // reconnecting - try again
        continue;
      }
      try {
        return await waiter.future.timeout(timeout);
      } on TimeoutException {
        // resend
      } finally {
        _replyWaiters.remove(jobId);
      }
    }
    return null;
  }

  void sendNfcProgress(String jobId, String step, bool ok, String detail) {
    _publish('evt/nfc_progress', jsonEncode({'job_id': jobId, 'step': step, 'ok': ok, 'detail': detail}));
  }

  /// evt/nfc_done - retried for a while if the link is down, so the PC always gets the result.
  Future<bool> sendNfcDone(String jobId, Map<String, Object> result) async {
    final payload = jsonEncode({'job_id': jobId, ...result});
    for (var i = 0; i < 10; i++) {
      if (_publish('evt/nfc_done', payload)) return true;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  bool sendScan(String qr) {
    if (!isPaired) return false;
    lastAck = null;
    verifyResult = null;
    notifyListeners();
    return _publish('evt/scan', jsonEncode({'qr': qr}));
  }

  bool _publish(String suffix, String payload, {bool retain = false}) {
    final client = _client;
    if (client == null || client.connectionStatus?.state != MqttConnectionState.connected) return false;
    _publishOn(client, suffix, payload, retain: retain);
    return true;
  }

  void _publishOn(MqttServerClient client, String suffix, String payload, {bool retain = false}) {
    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    client.publishMessage(_topic(suffix), MqttQos.atLeastOnce, builder.payload!, retain: retain);
  }

  @override
  void dispose() {
    disconnect();
    _nfcJobs.close();
    _nfcVerdicts.close();
    _nfcCancels.close();
    super.dispose();
  }
}
