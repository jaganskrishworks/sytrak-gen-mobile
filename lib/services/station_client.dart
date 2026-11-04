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
  final _nfcRequests = StreamController<NfcWriteRequest>.broadcast();

  Stream<NfcWriteRequest> get nfcRequests => _nfcRequests.stream;
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
        case 'nfc_write':
          _nfcRequests.add(NfcWriteRequest.fromJson(data));
      }
    }
  }

  bool sendScan(String qr) {
    if (!isPaired) return false;
    lastAck = null;
    verifyResult = null;
    notifyListeners();
    return _publish('evt/scan', jsonEncode({'qr': qr}));
  }

  /// [readBack] is the text read from the tag after writing (verification).
  void sendNfcResult(String seq, {required bool ok, String error = '', String? readBack}) {
    _publish('evt/nfc_result', jsonEncode({'seq': seq, 'ok': ok, 'error': error, 'read_back': ?readBack}));
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
    _nfcRequests.close();
    super.dispose();
  }
}
