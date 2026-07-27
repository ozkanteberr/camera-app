package com.example.camera_app.ar

import android.graphics.Bitmap
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.HandlerThread
import android.view.PixelCopy
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

internal class ArViewSnapshotter(
    private val mainHandler: Handler,
) {
    fun take(surfaceView: GLSurfaceView, result: MethodChannel.Result) {
        if (surfaceView.width <= 0 || surfaceView.height <= 0) {
            result.error("snapshot_unavailable", "AR view has no drawable size.", null)
            return
        }
        val bitmap = Bitmap.createBitmap(surfaceView.width, surfaceView.height, Bitmap.Config.ARGB_8888)
        val worker = HandlerThread("NativeArPixelCopy").apply { start() }
        PixelCopy.request(surfaceView, bitmap, { status ->
            if (status == PixelCopy.SUCCESS) {
                val stream = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                mainHandler.post {
                    result.success(stream.toByteArray())
                    bitmap.recycle()
                }
            } else {
                bitmap.recycle()
                mainHandler.post {
                    result.error("snapshot_failed", "PixelCopy failed with status $status.", null)
                }
            }
            worker.quitSafely()
        }, Handler(worker.looper))
    }
}
