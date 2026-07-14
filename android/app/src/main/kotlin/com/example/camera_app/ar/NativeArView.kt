package com.example.camera_app.ar

import android.Manifest
import android.app.Activity
import android.app.Application
import android.graphics.Bitmap
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.Surface
import android.view.View
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.HitResult
import com.google.ar.core.Plane
import com.google.ar.core.Point
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayOutputStream
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

class NativeArView(
    private val activity: Activity,
    context: android.content.Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, GLSurfaceView.Renderer, Application.ActivityLifecycleCallbacks {
    private val surfaceView = GLSurfaceView(context)
    private val sessionChannel = MethodChannel(messenger, "arsession_$viewId")
    private val objectChannel = MethodChannel(messenger, "arobjects_$viewId")
    private val anchorChannel = MethodChannel(messenger, "aranchors_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessionThread = HandlerThread("NativeArSession-$viewId").apply { start() }
    private val sessionHandler = Handler(sessionThread.looper)
    private val sessionLock = Any()
    private val backgroundRenderer = ArBackgroundRenderer()
    private val planeRenderer = ArPlaneRenderer()

    private var session: Session? = null
    private var latestFrame: Frame? = null
    @Volatile private var sessionResumed = false
    private var cameraTextureBound = false
    @Volatile private var disposed = false
    @Volatile private var activityResumed = true
    @Volatile private var initializationRequested = false
    @Volatile private var availabilityCheckInProgress = false
    @Volatile private var installCheckInProgress = false
    @Volatile private var arCoreReady = false
    @Volatile private var sessionStartInProgress = false
    @Volatile private var sessionReadyReported = false
    @Volatile private var startupStartedAtMs = 0L
    @Volatile private var lastReportedError: String? = null
    @Volatile private var showPlanes = true
    @Volatile private var planeCallbacksEnabled = true
    @Volatile private var configuredPlaneMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
    @Volatile private var surfaceWidth = 0
    @Volatile private var surfaceHeight = 0
    private var lastReportedPlaneCount = -1
    private var userRequestedInstall = true

    init {
        surfaceView.setEGLContextClientVersion(2)
        surfaceView.preserveEGLContextOnPause = true
        surfaceView.setRenderer(this)
        surfaceView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        surfaceView.setOnTouchListener { _, event -> handleTap(event) }
        sessionChannel.setMethodCallHandler(::handleSessionMethod)
        objectChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "addNode", "addNodeToPlaneAnchor" -> result.success(false)
                else -> result.success(null)
            }
        }
        anchorChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "addAnchor", "uploadAnchor", "downloadAnchor", "initGoogleCloudAnchorMode" -> result.success(false)
                else -> result.success(null)
            }
        }
        activity.application.registerActivityLifecycleCallbacks(this)
        surfaceView.onResume()
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        if (disposed) return
        disposed = true
        activityResumed = false
        activity.application.unregisterActivityLifecycleCallbacks(this)
        sessionChannel.setMethodCallHandler(null)
        objectChannel.setMethodCallHandler(null)
        anchorChannel.setMethodCallHandler(null)
        surfaceView.onPause()
        sessionHandler.post {
            synchronized(sessionLock) {
                runCatching { if (sessionResumed) session?.pause() }
                sessionResumed = false
                latestFrame = null
                session?.close()
                session = null
            }
            sessionThread.quitSafely()
        }
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        backgroundRenderer.createOnGlThread()
        planeRenderer.createOnGlThread()
        synchronized(sessionLock) { cameraTextureBound = false }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        surfaceWidth = width
        surfaceHeight = height
        GLES20.glViewport(0, 0, width, height)
        synchronized(sessionLock) {
            session?.setDisplayGeometry(currentRotation(), width, height)
        }
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        synchronized(sessionLock) {
            val activeSession = session ?: return
            if (!sessionResumed || backgroundRenderer.textureId == 0) return
            try {
                if (!cameraTextureBound) {
                    activeSession.setCameraTextureNames(intArrayOf(backgroundRenderer.textureId))
                    cameraTextureBound = true
                }
                val frame = activeSession.update()
                latestFrame = frame
                backgroundRenderer.draw(frame)
                if (!sessionReadyReported && frame.timestamp != 0L) {
                    sessionReadyReported = true
                    Log.i(TAG, "First camera frame in ${SystemClock.elapsedRealtime() - startupStartedAtMs} ms")
                    mainHandler.post {
                        if (!disposed) sessionChannel.invokeMethod("onSessionReady", null)
                    }
                }
                val trackedPlanes = activeSession.getAllTrackables(Plane::class.java)
                    .filter { it.trackingState == TrackingState.TRACKING && it.subsumedBy == null }
                if (showPlanes) planeRenderer.draw(frame.camera, trackedPlanes)
                reportPlaneCount(trackedPlanes.size)
            } catch (error: Exception) {
                postError("AR frame update failed: ${error.message ?: error.javaClass.simpleName}")
            }
        }
    }

    private fun handleSessionMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                initializationRequested = true
                if (startupStartedAtMs == 0L) startupStartedAtMs = SystemClock.elapsedRealtime()
                showPlanes = call.argument<Boolean>("showPlanes") ?: true
                configuredPlaneMode = planeModeFor(call.argument<Int>("planeDetectionConfig") ?: 3)
                planeCallbacksEnabled = configuredPlaneMode != Config.PlaneFindingMode.DISABLED
                sessionHandler.post {
                    synchronized(sessionLock) { configureSessionLocked() }
                }
                startSessionAsync()
                result.success(null)
            }
            "getCameraPose" -> synchronized(sessionLock) {
                val pose = latestFrame?.camera?.displayOrientedPose
                if (pose == null) result.error("ar_not_ready", "Camera pose is not available yet.", null)
                else result.success(serializePose(pose))
            }
            "hitTestPlaneQuad" -> synchronized(sessionLock) {
                result.success(hitTestPlaneQuadLocked(call))
            }
            "hitTestPlaneViewport" -> synchronized(sessionLock) {
                result.success(hitTestPlaneViewportLocked(call))
            }
            "snapshot" -> takeSnapshot(result)
            "showPlanes" -> {
                showPlanes = call.argument<Boolean>("showPlanes") ?: false
                result.success(null)
            }
            "setPlaneDetectionEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                planeCallbacksEnabled = enabled
                sessionHandler.post {
                    synchronized(sessionLock) {
                        session?.let { activeSession ->
                            val config = activeSession.config
                            config.planeFindingMode = if (enabled) configuredPlaneMode else Config.PlaneFindingMode.DISABLED
                            activeSession.configure(config)
                        }
                    }
                }
                result.success(null)
            }
            "disableCamera" -> {
                surfaceView.visibility = View.INVISIBLE
                result.success(null)
            }
            "enableCamera" -> {
                surfaceView.visibility = View.VISIBLE
                result.success(null)
            }
            "dispose" -> {
                result.success(null)
                dispose()
            }
            "getAnchorPose" -> result.error("unsupported", "Anchors are not used by the surface scanner.", null)
            else -> result.notImplemented()
        }
    }

    private fun startSessionAsync() {
        if (!initializationRequested || disposed || !activityResumed || sessionResumed || sessionStartInProgress) return
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            postError("Camera permission is required for AR.")
            return
        }
        if (session != null || arCoreReady) {
            queueSessionStart()
            return
        }
        checkArCoreAvailabilityAsync()
    }

    private fun checkArCoreAvailabilityAsync() {
        if (availabilityCheckInProgress || disposed) return
        availabilityCheckInProgress = true
        val checkStartedAt = SystemClock.elapsedRealtime()
        ArCoreApk.getInstance().checkAvailabilityAsync(activity.applicationContext) { availability ->
            availabilityCheckInProgress = false
            if (disposed) return@checkAvailabilityAsync
            Log.i(TAG, "Availability $availability in ${SystemClock.elapsedRealtime() - checkStartedAt} ms")
            when (availability) {
                ArCoreApk.Availability.SUPPORTED_INSTALLED -> {
                    verifyInstalledArCoreAsync()
                }
                ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED,
                ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD -> requestArCoreInstall()
                else -> postError("ARCore is not supported on this device: $availability")
            }
        }
    }

    private fun verifyInstalledArCoreAsync() {
        if (installCheckInProgress || disposed) return
        installCheckInProgress = true
        sessionHandler.post {
            try {
                val installStartedAt = SystemClock.elapsedRealtime()
                when (ArCoreApk.getInstance().requestInstall(activity, userRequestedInstall)) {
                    ArCoreApk.InstallStatus.INSTALL_REQUESTED -> userRequestedInstall = false
                    ArCoreApk.InstallStatus.INSTALLED -> arCoreReady = true
                }
                Log.i(TAG, "Installed ARCore verified in ${SystemClock.elapsedRealtime() - installStartedAt} ms")
            } catch (error: Exception) {
                postError("ARCore installation check failed: ${error.message ?: error.javaClass.simpleName}")
            } finally {
                installCheckInProgress = false
            }
            if (arCoreReady) queueSessionStart()
        }
    }

    private fun requestArCoreInstall() {
        try {
            val installStartedAt = SystemClock.elapsedRealtime()
            when (ArCoreApk.getInstance().requestInstall(activity, userRequestedInstall)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> userRequestedInstall = false
                ArCoreApk.InstallStatus.INSTALLED -> {
                    arCoreReady = true
                    queueSessionStart()
                }
            }
            Log.i(TAG, "Install request handled in ${SystemClock.elapsedRealtime() - installStartedAt} ms")
        } catch (error: Exception) {
            postError("ARCore installation check failed: ${error.message ?: error.javaClass.simpleName}")
        }
    }

    private fun queueSessionStart() {
        if (disposed || !activityResumed || sessionResumed || sessionStartInProgress) return
        sessionStartInProgress = true
        sessionHandler.post {
            try {
                synchronized(sessionLock) {
                    if (disposed || !activityResumed) return@synchronized
                    if (session == null) {
                        val createStartedAt = SystemClock.elapsedRealtime()
                        session = Session(activity)
                        Log.i(TAG, "Session created in ${SystemClock.elapsedRealtime() - createStartedAt} ms")
                        configureSessionLocked()
                        if (surfaceWidth > 0 && surfaceHeight > 0) {
                            session?.setDisplayGeometry(currentRotation(), surfaceWidth, surfaceHeight)
                        }
                        cameraTextureBound = false
                        sessionReadyReported = false
                    }
                    if (!sessionResumed && activityResumed) {
                        val resumeStartedAt = SystemClock.elapsedRealtime()
                        session?.resume()
                        sessionResumed = true
                        Log.i(TAG, "Session resumed in ${SystemClock.elapsedRealtime() - resumeStartedAt} ms")
                    }
                }
            } catch (error: Exception) {
                postError("ARCore could not start: ${error.message ?: error.javaClass.simpleName}")
            } finally {
                sessionStartInProgress = false
            }
        }
    }

    private fun pauseSessionAsync() {
        sessionHandler.post {
            synchronized(sessionLock) {
                if (!sessionResumed) return@synchronized
                runCatching { session?.pause() }
                sessionResumed = false
            }
        }
    }

    private fun configureSessionLocked() {
        val activeSession = session ?: return
        val config = activeSession.config
        config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
        config.focusMode = Config.FocusMode.AUTO
        config.planeFindingMode = if (planeCallbacksEnabled) configuredPlaneMode else Config.PlaneFindingMode.DISABLED
        activeSession.configure(config)
    }

    private fun planeModeFor(index: Int): Config.PlaneFindingMode = when (index) {
        0 -> Config.PlaneFindingMode.DISABLED
        1 -> Config.PlaneFindingMode.HORIZONTAL
        2 -> Config.PlaneFindingMode.VERTICAL
        else -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
    }

    @Suppress("DEPRECATION")
    private fun currentRotation(): Int =
        activity.windowManager.defaultDisplay?.rotation ?: Surface.ROTATION_0

    private fun reportPlaneCount(count: Int) {
        if (!planeCallbacksEnabled || count == lastReportedPlaneCount) return
        lastReportedPlaneCount = count
        mainHandler.post { if (!disposed) sessionChannel.invokeMethod("onPlaneDetected", count) }
    }

    private fun postError(message: String) {
        if (disposed || lastReportedError == message) return
        lastReportedError = message
        mainHandler.post {
            if (!disposed) sessionChannel.invokeMethod("onError", listOf(message))
        }
    }

    private fun serializePose(pose: Pose): DoubleArray {
        val matrix = FloatArray(16)
        pose.toMatrix(matrix, 0)
        return DoubleArray(matrix.size) { matrix[it].toDouble() }
    }

    private fun hitTestPlaneAtLocked(
        frame: Frame,
        normalizedX: Float,
        normalizedY: Float,
        requiredPlane: Plane? = null,
    ): HitResult? {
        if (surfaceWidth <= 0 || surfaceHeight <= 0) return null
        val x = normalizedX.coerceIn(0f, 1f) * surfaceWidth
        val y = normalizedY.coerceIn(0f, 1f) * surfaceHeight
        return frame.hitTest(x, y).firstOrNull { hit ->
            val plane = hit.trackable as? Plane ?: return@firstOrNull false
            plane.trackingState == TrackingState.TRACKING &&
                plane.isPoseInPolygon(hit.hitPose) &&
                (requiredPlane == null || requiredPlane == plane)
        }
    }

    private fun hitTestPlaneQuadLocked(call: MethodCall): ArrayList<DoubleArray>? {
        val frame = latestFrame ?: return null
        val points = call.argument<List<Map<String, Any>>>("points") ?: return null
        if (points.isEmpty()) return null
        val output = ArrayList<DoubleArray>(points.size)
        var selectedPlane: Plane? = null
        for (point in points) {
            val x = (point["x"] as? Number)?.toFloat() ?: return null
            val y = (point["y"] as? Number)?.toFloat() ?: return null
            val hit = hitTestPlaneAtLocked(frame, x, y, selectedPlane) ?: return null
            selectedPlane = hit.trackable as Plane
            output.add(serializePose(hit.hitPose))
        }
        return output
    }

    private fun hitTestPlaneViewportLocked(call: MethodCall): HashMap<String, Any>? {
        val frame = latestFrame ?: return null
        val columns = (call.argument<Int>("columns") ?: 9).coerceIn(3, 15)
        val rows = (call.argument<Int>("rows") ?: 13).coerceIn(3, 19)
        val marginX = ((call.argument<Any>("horizontalMargin") as? Number)?.toFloat() ?: 0.04f)
            .coerceIn(0f, 0.25f)
        val marginY = ((call.argument<Any>("verticalMargin") as? Number)?.toFloat() ?: 0.06f)
            .coerceIn(0f, 0.25f)
        val leftLimit = marginX
        val rightLimit = 1f - marginX
        val topLimit = marginY
        val bottomLimit = 1f - marginY
        if (rightLimit <= leftLimit || bottomLimit <= topLimit) return null
        val stepX = (rightLimit - leftLimit) / (columns - 1)
        val stepY = (bottomLimit - topLimit) / (rows - 1)
        val hitsByPlane = HashMap<Plane, MutableList<Pair<Float, Float>>>()

        for (row in 0 until rows) {
            val y = topLimit + stepY * row
            for (column in 0 until columns) {
                val x = leftLimit + stepX * column
                val hit = hitTestPlaneAtLocked(frame, x, y) ?: continue
                val plane = hit.trackable as Plane
                hitsByPlane.getOrPut(plane) { mutableListOf() }.add(Pair(x, y))
            }
        }
        val selected = hitsByPlane.maxByOrNull { it.value.size } ?: return null
        if (selected.value.size < 4) return null
        val plane = selected.key
        val minX = selected.value.minOf { it.first }
        val maxX = selected.value.maxOf { it.first }
        val minY = selected.value.minOf { it.second }
        val maxY = selected.value.maxOf { it.second }
        val baseLeft = (minX - stepX * 0.5f).coerceIn(leftLimit, rightLimit)
        val baseRight = (maxX + stepX * 0.5f).coerceIn(leftLimit, rightLimit)
        val baseTop = (minY - stepY * 0.5f).coerceIn(topLimit, bottomLimit)
        val baseBottom = (maxY + stepY * 0.5f).coerceIn(topLimit, bottomLimit)
        if (baseRight - baseLeft < 0.14f || baseBottom - baseTop < 0.14f) return null

        for (shrink in floatArrayOf(0f, 0.015f, 0.03f, 0.05f, 0.075f, 0.10f)) {
            val left = (baseLeft + shrink).coerceIn(leftLimit, rightLimit)
            val right = (baseRight - shrink).coerceIn(leftLimit, rightLimit)
            val top = (baseTop + shrink).coerceIn(topLimit, bottomLimit)
            val bottom = (baseBottom - shrink).coerceIn(topLimit, bottomLimit)
            if (right - left < 0.12f || bottom - top < 0.12f) continue
            val corners = listOf(Pair(left, top), Pair(right, top), Pair(right, bottom), Pair(left, bottom))
            val hits = ArrayList<DoubleArray>(4)
            for (corner in corners) {
                val hit = hitTestPlaneAtLocked(frame, corner.first, corner.second, plane) ?: break
                hits.add(serializePose(hit.hitPose))
            }
            if (hits.size == 4) {
                return hashMapOf(
                    "rect" to arrayListOf(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble()),
                    "hits" to hits,
                )
            }
        }
        return null
    }

    private fun takeSnapshot(result: MethodChannel.Result) {
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

    private fun handleTap(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_UP) return true
        val hits = synchronized(sessionLock) {
            val frame = latestFrame ?: return@synchronized emptyList<HashMap<String, Any>>()
            frame.hitTest(event.x, event.y)
                .filter { hit ->
                    val trackable = hit.trackable
                    (trackable is Plane && trackable.isPoseInPolygon(hit.hitPose)) || trackable is Point
                }
                .map { serializeHit(it) }
        }
        if (hits.isNotEmpty()) {
            sessionChannel.invokeMethod("onPlaneOrPointTap", hits)
        }
        return true
    }

    private fun serializeHit(hit: HitResult): HashMap<String, Any> {
        val type = when (hit.trackable) {
            is Plane -> 1
            is Point -> 2
            else -> 0
        }
        return hashMapOf(
            "type" to type,
            "distance" to hit.distance.toDouble(),
            "worldTransform" to serializePose(hit.hitPose),
        )
    }

    override fun onActivityResumed(resumedActivity: Activity) {
        if (resumedActivity !== activity || disposed) return
        activityResumed = true
        surfaceView.onResume()
        startSessionAsync()
    }

    override fun onActivityPaused(pausedActivity: Activity) {
        if (pausedActivity !== activity || disposed) return
        activityResumed = false
        pauseSessionAsync()
        surfaceView.onPause()
    }

    override fun onActivityDestroyed(destroyedActivity: Activity) {
        if (destroyedActivity === activity) dispose()
    }

    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit

    private companion object {
        const val TAG = "NativeArStartup"
    }
}
