import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Stable identity of this phone (its MQTT client id) plus remembered settings.
class Identity {
  Identity._(this._prefs, this.id);

  final SharedPreferences _prefs;

  /// Mobile id - also the MQTT client id. Never changes after first launch.
  final String id;

  static Future<Identity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('mobile_id');
    if (id == null) {
      final rnd = Random.secure();
      id = 'mob-${List.generate(4, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      await prefs.setString('mobile_id', id);
    }
    return Identity._(prefs, id);
  }

  String get name => _prefs.getString('mobile_name') ?? 'Mobile ${id.substring(id.length - 4).toUpperCase()}';
  set name(String value) => _prefs.setString('mobile_name', value.trim());

  String passwordFor(String stationId) => _prefs.getString('pwd_$stationId') ?? '';
  void savePassword(String stationId, String password) => _prefs.setString('pwd_$stationId', password);

  List<String> get manualHosts => _prefs.getStringList('manual_hosts') ?? const [];
  void addManualHost(String host) {
    final hosts = {...manualHosts, host}.toList();
    _prefs.setStringList('manual_hosts', hosts);
  }
}
