import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer_client/main.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => Directory.systemTemp.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app loads', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = _FakePaths();
    await tester.pumpWidget(const LanTransferApp());
    expect(find.text('局域网快传'), findsWidgets);
  });
}
