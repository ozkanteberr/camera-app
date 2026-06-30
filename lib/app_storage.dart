import 'package:hive/hive.dart';
import 'package:hive_flutter/adapters.dart';

class AppStorage {
  static Future<void> appStorageInitialize() async {
    await Hive.initFlutter();
    await Hive.openBox('settingsBox');
    await Hive.openBox<String>('photosBox');
  }

  static final Box localBox = Hive.box('settingsBox');
}
