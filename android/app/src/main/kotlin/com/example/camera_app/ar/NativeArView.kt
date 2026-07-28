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
import android.util.Log
import android.view.MotionEvent
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
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var disposed = false
    private val channels = ArPlatformChannels(messenger, viewId, mainHandler) { disposed }
    private val sessionThread = HandlerThread("NativeArSession-$viewId").apply { start() }
    private val sessionHandler = Handler(sessionThread.looper)
    private val sessionLock = Any()
    private val pipeline = ArFrameSurfacePipeline()
    private val snapshotter = ArViewSnapshotter(mainHandler)

    private var session: Session? = null
    @Volatile private var sessionResumed = false
    private var cameraTextureBound = false
    @Volatile private var activityResumed = true
    @Volatile private var initRequested = false
    @Volatile private var availabilityCheckInProgress = false
    @Volatile private var installCheckInProgress = false
    @Volatile private var arCoreReady = false
    @Volatile private var sessionStarting = false
    @Volatile private var readyReported = false
    @Volatile private var showPlanes = true
    @Volatile private var callbacksEnabled = true
    @Volatile private var planeMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
    @Volatile private var depthSupported = false
    private var userRequestedInstall = true

    init {
        surfaceView.setEGLContextClientVersion(2)
        surfaceView.preserveEGLContextOnPause = true
        surfaceView.setRenderer(this)
        surfaceView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        surfaceView.setOnTouchListener { _, event -> handleTap(event) }
        channels.setSessionMethodCallHandler(::handleSessionMethod)
        activity.application.registerActivityLifecycleCallbacks(this)
        surfaceView.onResume()
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        if (disposed) return
        disposed = true
        activityResumed = false
        activity.application.unregisterActivityLifecycleCallbacks(this)
        channels.clearMethodCallHandlers()
        surfaceView.onPause()
        sessionHandler.post {
            synchronized(sessionLock) {
                runCatching { if (sessionResumed) session?.pause() }
                sessionResumed = false
                pipeline.reset()
                session?.close()
                session = null
            }
            sessionThread.quitSafely()
        }
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        pipeline.createOnGlThread()
        synchronized(sessionLock) { cameraTextureBound = false }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        pipeline.onSurfaceChanged(width, height)
        GLES20.glViewport(0, 0, width, height)
        synchronized(sessionLock) {
            session?.setDisplayGeometry(activity.displayRotation(), width, height)
        }
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        synchronized(sessionLock) {
            val activeSession = session ?: return
            if (!sessionResumed || pipeline.cameraTextureId == 0) return
            try {
                if (!cameraTextureBound) {
                    activeSession.setCameraTextureNames(intArrayOf(pipeline.cameraTextureId))
                    cameraTextureBound = true
                }
                val frameUpdate = pipeline.drawFrame(activeSession, showPlanes, depthSupported)
                if (!readyReported && frameUpdate.timestamp != 0L) {
                    readyReported = true
                    channels.reportSessionReady()
                }
                channels.reportPlaneCount(frameUpdate.detectedSurfaceCount, callbacksEnabled)
                channels.reportSurfaceState(frameUpdate.surfaceState)
            } catch (error: Exception) {
                channels.reportError("AR frame update failed: ${error.message ?: error.javaClass.simpleName}")
            }
        }
    }

    private fun handleSessionMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                initRequested = true
                showPlanes = call.argument<Boolean>("showPlanes") ?: true
                planeMode = planeFindingModeFor(call.argument<Int>("planeDetectionConfig") ?: 3)
                callbacksEnabled = planeMode != Config.PlaneFindingMode.DISABLED
                sessionHandler.post {
                    synchronized(sessionLock) { configureSessionLocked() }
                }
                startSessionAsync()
                result.success(null)
            }
            "getCameraPose" -> synchronized(sessionLock) {
                val pose = pipeline.cameraPose()
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
            "setSurfaceScanMode" -> {
                val mode = ArSurfaceScanMode.fromWireValue(call.argument("mode"))
                callbacksEnabled = true
                sessionHandler.post {
                    synchronized(sessionLock) {
                        pipeline.setScanMode(mode)
                        channels.resetPlaneCount()
                        session?.let { activeSession ->
                            val config = activeSession.config
                            config.planeFindingMode = planeMode
                            activeSession.configure(config)
                        }
                    }
                }
                result.success(null)
            }
            "setPlaneDetectionEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val restart = enabled && !callbacksEnabled
                callbacksEnabled = enabled
                sessionHandler.post {
                    synchronized(sessionLock) {
                        if (restart) {
                            runCatching { if (sessionResumed) session?.pause() }
                            sessionResumed = false
                            pipeline.reset()
                            runCatching { session?.close() }
                            session = null
                            cameraTextureBound = false
                            readyReported = false
                            channels.resetPlaneCount()
                        } else {
                            if (enabled) {
                                pipeline.restartPlaneSelection()
                                channels.resetPlaneCount()
                            }
                            session?.let { pipeline.setSurfaceLocked(it, !enabled) }
                            session?.let { activeSession ->
                                val config = activeSession.config
                                config.planeFindingMode = if (enabled) planeMode else Config.PlaneFindingMode.DISABLED
                                activeSession.configure(config)
                            }
                        }
                    }
                    if (restart) queueSessionStart()
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
        if (!initRequested || disposed || !activityResumed || sessionResumed || sessionStarting) return
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            channels.reportError("Camera permission is required for AR.")
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
        ArCoreApk.getInstance().checkAvailabilityAsync(activity.applicationContext) { availability ->
            availabilityCheckInProgress = false
            if (disposed) return@checkAvailabilityAsync
            when (availability) {
                ArCoreApk.Availability.SUPPORTED_INSTALLED -> {
                    verifyInstalledArCoreAsync()
                }
                ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED,
                ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD -> requestArCoreInstall()
                else -> channels.reportError("ARCore is not supported on this device: $availability")
            }
        }
    }

    private fun verifyInstalledArCoreAsync() {
        if (installCheckInProgress || disposed) return
        installCheckInProgress = true
        sessionHandler.post {
            try {
                when (ArCoreApk.getInstance().requestInstall(activity, userRequestedInstall)) {
                    ArCoreApk.InstallStatus.INSTALL_REQUESTED -> userRequestedInstall = false
                    ArCoreApk.InstallStatus.INSTALLED -> arCoreReady = true
                }
            } catch (error: Exception) {
                channels.reportError("ARCore installation check failed: ${error.message ?: error.javaClass.simpleName}")
            } finally {
                installCheckInProgress = false
            }
            if (arCoreReady) queueSessionStart()
        }
    }

    private fun requestArCoreInstall() {
        try {
            when (ArCoreApk.getInstance().requestInstall(activity, userRequestedInstall)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> userRequestedInstall = false
                ArCoreApk.InstallStatus.INSTALLED -> {
                    arCoreReady = true
                    queueSessionStart()
                }
            }
        } catch (error: Exception) {
            channels.reportError("ARCore installation check failed: ${error.message ?: error.javaClass.simpleName}")
        }
    }

    private fun queueSessionStart() {
        if (disposed || !activityResumed || sessionResumed || sessionStarting) return
        sessionStarting = true
        sessionHandler.post {
            try {
                synchronized(sessionLock) {
                    if (disposed || !activityResumed) return@synchronized
                    if (session == null) {
                        session = Session(activity)
                        configureSessionLocked()
                        session?.let { pipeline.applyDisplayGeometry(it, activity.displayRotation()) }
                        cameraTextureBound = false
                        readyReported = false
                    }
                    if (!sessionResumed && activityResumed) {
                        session?.resume()
                        sessionResumed = true
                    }
                }
            } catch (error: Exception) {
                channels.reportError("ARCore could not start: ${error.message ?: error.javaClass.simpleName}")
            } finally {
                sessionStarting = false
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
        config.planeFindingMode = if (callbacksEnabled) planeMode else Config.PlaneFindingMode.DISABLED
        depthSupported = activeSession.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
        config.depthMode = if (depthSupported) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED
        activeSession.configure(config)
        Log.i(TAG, "Depth API supported: $depthSupported")
    }

    private fun hitTestPlaneQuadLocked(call: MethodCall): ArrayList<DoubleArray>? =
        call.planePoints()?.let(pipeline::hitTestPlaneQuad)

    private fun hitTestPlaneViewportLocked(call: MethodCall): HashMap<String, Any>? {
        val request = call.viewportRequest()
        return pipeline.hitTestPlaneViewport(
            request.columns,
            request.rows,
            request.marginX,
            request.marginY,
        )
    }

    private fun handleTap(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_UP) return true
        val hits = synchronized(sessionLock) {
            pipeline.hitTestTap(event.x, event.y)
        }
        channels.reportTap(hits)
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
