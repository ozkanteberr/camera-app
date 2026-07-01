import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OCRPainter extends CustomPainter {
  final RecognizedText recognizedText;
  final Size absoluteImageSize;
  final InputImageRotation rotation;

  OCRPainter(this.recognizedText, this.absoluteImageSize, this.rotation);

  @override
  void paint(Canvas canvas, Size size) {
    // Kutucuk fırçası
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.orangeAccent;

    // Her bir metin bloğunu döngüyle gez
    for (final block in recognizedText.blocks) {
      // Koordinatları oranla (Scaling)
      final rect = _scaleRect(block.boundingBox, size, absoluteImageSize);

      // Dikdörtgeni çiz
      canvas.drawRect(rect, paint);

      // metin bilgisini de ekrana yazdırma
      TextPainter(
        text: TextSpan(
          text: block.text,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              backgroundColor: Colors.orange),
        ),
        textDirection: TextDirection.ltr,
      )
        ..layout()
        ..paint(canvas, Offset(rect.left, rect.top - 20));
    }
  }

  // Koordinatları ekrana göre ölçeklendiren yardımcı fonksiyon
  Rect _scaleRect(Rect rect, Size canvasSize, Size imageSize) {
    return Rect.fromLTRB(
      rect.left * canvasSize.width / imageSize.width,
      rect.top * canvasSize.height / imageSize.height,
      rect.right * canvasSize.width / imageSize.width,
      rect.bottom * canvasSize.height / imageSize.height,
    );
  }

  @override
  bool shouldRepaint(covariant OCRPainter oldDelegate) {
    return oldDelegate.recognizedText != recognizedText;
  }
}
