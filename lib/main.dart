import 'package:camera_app/core/storage/app_storage.dart';
import 'package:camera_app/providers/camera_provider.dart';
import 'package:camera_app/providers/ocr_provider.dart';
import 'package:camera_app/providers/pose_provider.dart';
import 'package:camera_app/providers/smart_selfie_provider.dart';
import 'package:camera_app/screens/home_screen.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:provider/provider.dart';

void main() async {
  //aysnc işlemler için gerekli
  WidgetsFlutterBinding.ensureInitialized();
  //dil paketini başlat
  await EasyLocalization.ensureInitialized();
  // hive başlat
  await AppStorage.appStorageInitialize();

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en', 'US'), Locale('tr', 'TR')],
      path: "assets/translations",
      fallbackLocale: const Locale('tr', 'TR'),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider(
              create: (_) => CameraProvider()..loadSavedPhotos()),
          ChangeNotifierProvider(create: (_) => PoseProvider()),
          ChangeNotifierProvider(create: (_) => OcrProvider()),
          ChangeNotifierProvider(create: (_) => SmartSelfieProvider()),
        ],
        child: const MyApp(),
      ),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilPlusInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Kamera App',
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
            useMaterial3: true,
          ),
          home: child,
        );
      },
      child: const HomeScreen(),
    );
  }
}
