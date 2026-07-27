package com.example.camera_app.ar

import android.os.Handler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal data class ArViewportRequest(
    val columns: Int,
    val rows: Int,
    val marginX: Float,
    val marginY: Float,
)

internal fun MethodCall.planePoints(): List<Map<String, Any>>? = argument("points")

internal fun MethodCall.viewportRequest() = ArViewportRequest(
    columns = (argument<Int>("columns") ?: 9).coerceIn(3, 15),
    rows = (argument<Int>("rows") ?: 13).coerceIn(3, 19),
    marginX = ((argument<Any>("horizontalMargin") as? Number)?.toFloat() ?: 0.04f)
        .coerceIn(0f, 0.25f),
    marginY = ((argument<Any>("verticalMargin") as? Number)?.toFloat() ?: 0.06f)
        .coerceIn(0f, 0.25f),
)

internal class ArPlatformChannels(
    messenger: BinaryMessenger,
    viewId: Int,
    private val mainHandler: Handler,
    private val isDisposed: () -> Boolean,
) {
    private val sessionChannel = MethodChannel(messenger, "arsession_$viewId")
    private val objectChannel = MethodChannel(messenger, "arobjects_$viewId")
    private val anchorChannel = MethodChannel(messenger, "aranchors_$viewId")
    @Volatile private var lastReportedError: String? = null
    private var lastReportedPlaneCount = -1

    init {
        objectChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "addNode", "addNodeToPlaneAnchor" -> result.success(false)
                else -> result.success(null)
            }
        }
        anchorChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "addAnchor", "uploadAnchor", "downloadAnchor", "initGoogleCloudAnchorMode" ->
                    result.success(false)
                else -> result.success(null)
            }
        }
    }

    fun setSessionMethodCallHandler(handler: MethodChannel.MethodCallHandler) {
        sessionChannel.setMethodCallHandler(handler)
    }

    fun clearMethodCallHandlers() {
        sessionChannel.setMethodCallHandler(null)
        objectChannel.setMethodCallHandler(null)
        anchorChannel.setMethodCallHandler(null)
    }

    fun reportSessionReady() {
        mainHandler.post {
            if (!isDisposed()) sessionChannel.invokeMethod("onSessionReady", null)
        }
    }

    fun reportPlaneCount(count: Int, callbacksEnabled: Boolean) {
        if (!callbacksEnabled || count == lastReportedPlaneCount) return
        lastReportedPlaneCount = count
        mainHandler.post {
            if (!isDisposed()) sessionChannel.invokeMethod("onPlaneDetected", count)
        }
    }

    fun resetPlaneCount() {
        lastReportedPlaneCount = -1
    }

    fun reportError(message: String) {
        if (isDisposed() || lastReportedError == message) return
        lastReportedError = message
        mainHandler.post {
            if (!isDisposed()) sessionChannel.invokeMethod("onError", listOf(message))
        }
    }

    fun reportTap(hits: List<HashMap<String, Any>>) {
        if (hits.isNotEmpty()) sessionChannel.invokeMethod("onPlaneOrPointTap", hits)
    }
}
