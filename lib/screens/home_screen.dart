import 'package:camera_app/screens/ocr_screen.dart';
import 'package:camera_app/screens/pose_screen.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'camera_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text("ML Kit Laboratuvarı",
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          PopupMenuButton<Locale>(
            icon: const Icon(Icons.language),
            onSelected: (Locale locale) {
              context.setLocale(locale); // Tüm uygulamada dili değiştirir
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: Locale('tr', 'TR'),
                child: Text("🇹🇷 Türkçe"),
              ),
              const PopupMenuItem(
                value: Locale('en', 'US'),
                child: Text("🇺🇸 English"),
              ),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "home_screen_title".tr(),
              style: TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),

            // (Face Detection)
            _buildMenuCard(
              context,
              title: "face_detection_title".tr(),
              subtitle: "face_detection_subtitle".tr(),
              icon: Icons.face_retouching_natural,
              color: Colors.blueAccent,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const CameraScreen()),
                );
              },
            ),
            const SizedBox(height: 16),

            //(Text Recognition)
            _buildMenuCard(
              context,
              title: "text_recognition_title".tr(),
              subtitle: "text_recognition_subtitle".tr(),
              icon: Icons.document_scanner,
              color: Colors.orangeAccent,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const OCRScreen()),
                );
              },
            ),
            const SizedBox(height: 16),

            //(Pose Detection)
            _buildMenuCard(
              context,
              title: "pose_detection_title".tr(),
              subtitle: "pose_detection_subtitle".tr(),
              icon: Icons.accessibility_new,
              color: Colors.greenAccent,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const PoseScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // Şık ve modern menü kartları oluşturan yardımcı widget
  Widget _buildMenuCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color, // Artık sadece ikonu renklendirecek
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(
              0xFF1E1E1E), // Bütün kartların arka planı mat koyu gri
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color.withOpacity(0.35), width: 1.0),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(
                    0.15), // İkonun arkasında çok hafif bir yuvarlak
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 32), // İkon kendi renginde
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios,
                color: Colors.white30, size: 16),
          ],
        ),
      ),
    );
  }
}
