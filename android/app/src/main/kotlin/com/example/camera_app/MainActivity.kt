package com.example.camera_app

import com.example.camera_app.ar.NativeArViewFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine
            .platformViewsController
            .registry
            .registerViewFactory(
                NativeArViewFactory.VIEW_TYPE,
                NativeArViewFactory(this, flutterEngine.dartExecutor.binaryMessenger),
            )
    }
}
