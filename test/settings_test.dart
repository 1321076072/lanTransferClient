import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer_client/models/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settings survive a reload', () async {
    SharedPreferences.setMockInitialValues({});
    final saved = AppSettings()
      ..role = 'sender'
      ..port = 5001
      ..targetIp = '10.0.0.8'
      ..saveDir = '/tmp/lan'
      ..resume = false
      ..verify = true
      ..verifyAlgo = 'sha256'
      ..encrypt = true
      ..password = 'secret'
      ..sync = true
      ..rateMbps = 12.5;
    await saved.save();

    final loaded = AppSettings();
    await loaded.load();
    expect(loaded.role, 'sender');
    expect(loaded.port, 5001);
    expect(loaded.targetIp, '10.0.0.8');
    expect(loaded.saveDir, '/tmp/lan');
    expect(loaded.resume, isFalse);
    expect(loaded.verifyAlgo, 'sha256');
    expect(loaded.encrypt, isTrue);
    expect(loaded.password, 'secret');
    expect(loaded.sync, isTrue);
    expect(loaded.rateMbps, 12.5);
  });
}
