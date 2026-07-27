package com.example.camera_app.ar

import android.Manifest
import android.app.Activity
import android.app.Application
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.MotionEvent
import android.view.Surface
import android.view.View
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Session
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
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
    private val frameSurfacePipeline = ArFrameSurfacePipeline()
    private val snapshotter = ArViewSnapshotter(mainHandler)

    private var session: Session? = null
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
    @Volatile private var depthSupported = false
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
                frameSurfacePipeline.reset()
                session?.close()
                session = null
            }
            sessionThread.quitSafely()
        }
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        frameSurfacePipeline.createOnGlThread()
        synchronized(sessionLock) { cameraTextureBound = false }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        frameSurfacePipeline.onSurfaceChanged(width, height)
        GLES20.glViewport(0, 0, width, height)
        synchronized(sessionLock) {
            session?.setDisplayGeometry(currentRotation(), width, height)
        }
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        synchronized(sessionLock) {
            val activeSession = session ?: return
            if (!sessionResumed || frameSurfacePipeline.cameraTextureId == 0) return
            try {
                if (!cameraTextureBound) {
                    activeSession.setCameraTextureNames(intArrayOf(frameSurfacePipeline.cameraTextureId))
                    cameraTextureBound = true
                }
                val frameUpdate = frameSurfacePipeline.drawFrame(activeSession, showPlanes, depthSupported)
                if (!sessionReadyReported && frameUpdate.timestamp != 0L) {
                    sessionReadyReported = true
                    Log.i(TAG, "First camera frame in ${SystemClock.elapsedRealtime() - startupStartedAtMs} ms")
                    mainHandler.post {
                        if (!disposed) sessionChannel.invokeMethod("onSessionReady", null)
                    }
                }
                reportPlaneCount(frameUpdate.detectedSurfaceCount)
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
                val pose = frameSurfacePipeline.cameraPose()
                if (pose == null) result.error("ar_not_ready", "Camera pose is not available yet.", null)
                else result.success(pose)
            }
            "hitTestPlaneQuad" -> synchronized(sessionLock) {
                result.success(hitTestPlaneQuadLocked(call))
            }
            "hitTestPlaneViewport" -> synchronized(sessionLock) {
                result.success(hitTestPlaneViewportLocked(call))
            }
            "snapshot" -> snapshotter.take(surfaceView, result)
            "showPlanes" -> {
                showPlanes = call.argument<Boolean>("showPlanes") ?: false
                result.success(null)
            }
            "setPlaneDetectionEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                planeCallbacksEnabled = enabled
                sessionHandler.post {
                    synchronized(sessionLock) {
                        frameSurfacePipeline.setDepthLocked(!enabled)
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
                        session?.let { frameSurfacePipeline.applyDisplayGeometry(it, currentRotation()) }
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
        depthSupported = activeSession.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
        config.depthMode = if (depthSupported) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED
        activeSession.configure(config)
        Log.i(TAG, "Depth API supported: $depthSupported")
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

    private fun hitTestPlaneQuadLocked(call: MethodCall): ArrayList<DoubleArray>? {
        val points = call.argument<List<Map<String, Any>>>("points") ?: return null
        return frameSurfacePipeline.hitTestPlaneQuad(points)
    }

    private fun hitTestPlaneViewportLocked(call: MethodCall): HashMap<String, Any>? {
        val columns = (call.argument<Int>("columns") ?: 9).coerceIn(3, 15)
        val rows = (call.argument<Int>("rows") ?: 13).coerceIn(3, 19)
        val marginX = ((call.argument<Any>("horizontalMargin") as? Number)?.toFloat() ?: 0.04f)
            .coerceIn(0f, 0.25f)
        val marginY = ((call.argument<Any>("verticalMargin") as? Number)?.toFloat() ?: 0.06f)
            .coerceIn(0f, 0.25f)
        return frameSurfacePipeline.hitTestPlaneViewport(
            columns,
            rows,
            marginX,
            marginY,
        )
    }

    private fun handleTap(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_UP) return true
        val hits = synchronized(sessionLock) {
            frameSurfacePipeline.hitTestTap(event.x, event.y)
        }
        if (hits.isNotEmpty()) {
            sessionChannel.invokeMethod("onPlaneOrPointTap", hits)
        }
        return true
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
