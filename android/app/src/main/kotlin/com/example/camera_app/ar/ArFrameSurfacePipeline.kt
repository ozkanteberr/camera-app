package com.example.camera_app.ar

import android.util.Log
import com.google.ar.core.DepthPoint
import com.google.ar.core.Plane
import com.google.ar.core.Point
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import android.os.SystemClock

internal data class ArFrameUpdate(
    val timestamp: Long,
    val detectedSurfaceCount: Int,
)

internal class ArFrameSurfacePipeline {
    private val backgroundRenderer = ArBackgroundRenderer()
    private val planeRenderer = ArPlaneRenderer()
    private val depthSurfaceRenderer = ArDepthSurfaceRenderer()
    private val depthSurfaceTracker = DepthSurfaceTracker()
    private val surfaceHitTester = ArSurfaceHitTester()
    private val activePlaneSelector = ArActivePlaneSelector()

    private var latestFrame: com.google.ar.core.Frame? = null
    private var latestDepthSurface: DepthSurface? = null
    private var lastDepthScanAtMs = 0L
    private var lastDepthSurfaceAtMs = 0L
    private var depthDetectionStreak = 0
    private var selectedPlane: Plane? = null
    @Volatile private var surfaceWidth = 0
    @Volatile private var surfaceHeight = 0

    val cameraTextureId: Int
        get() = backgroundRenderer.textureId

    fun createOnGlThread() {
        backgroundRenderer.createOnGlThread()
        planeRenderer.createOnGlThread()
        depthSurfaceRenderer.createOnGlThread()
    }

    fun onSurfaceChanged(width: Int, height: Int) {
        surfaceWidth = width
        surfaceHeight = height
    }

    fun applyDisplayGeometry(session: Session, rotation: Int) {
        if (surfaceWidth > 0 && surfaceHeight > 0) {
            session.setDisplayGeometry(rotation, surfaceWidth, surfaceHeight)
        }
    }

    fun drawFrame(
        session: Session,
        showPlanes: Boolean,
        depthSupported: Boolean,
    ): ArFrameUpdate {
        val frame = session.update()
        latestFrame = frame
        backgroundRenderer.draw(frame)
        val trackedPlanes = session.getAllTrackables(Plane::class.java)
            .filter { it.trackingState == TrackingState.TRACKING && it.subsumedBy == null }
        updateDepthSurface(frame, depthSupported)
        val activePlane = activePlaneSelector.select(
            frame,
            trackedPlanes,
            surfaceWidth,
            surfaceHeight,
            SystemClock.elapsedRealtime(),
        )
        selectedPlane = activePlane
        if (showPlanes) {
            activePlane?.let { planeRenderer.draw(frame.camera, listOf(it)) }
            if (activePlane == null && !activePlaneSelector.holdsSelection) {
                currentDepthSurface()?.let { depthSurface ->
                    if (!hasMatchingArCorePlane(depthSurface, trackedPlanes)) {
                        depthSurfaceRenderer.draw(frame.camera, depthSurface)
                    }
                }
            }
        }
        val detectedSurfaceCount = if (activePlane != null) {
            1
        } else if (!activePlaneSelector.holdsSelection &&
            depthDetectionStreak >= REQUIRED_DEPTH_DETECTION_STREAK
        ) {
            1
        } else {
            0
        }
        return ArFrameUpdate(frame.timestamp, detectedSurfaceCount)
    }

    fun cameraPose(): DoubleArray? = latestFrame?.camera?.displayOrientedPose?.let(::serializePose)

    fun hitTestPlaneQuad(points: List<Map<String, Any>>): ArrayList<DoubleArray>? {
        val frame = latestFrame ?: return null
        if (points.isEmpty()) return null
        val targetPlane = selectedPlane
        if (targetPlane == null && activePlaneSelector.holdsSelection) return null
        val planeHits = surfaceHitTester.hitTestPlaneQuad(
            frame,
            surfaceWidth,
            surfaceHeight,
            points,
            targetPlane,
        )
        if (targetPlane != null || planeHits != null) return planeHits
        val depthSurface = currentDepthSurface() ?: return null
        if (points.size != 4 || depthSurface.corners.size != 4) return null
        return ArrayList(depthSurface.corners.map(::serializePose))
    }

    fun hitTestPlaneViewport(
        columns: Int,
        rows: Int,
        marginX: Float,
        marginY: Float,
    ): HashMap<String, Any>? {
        val frame = latestFrame ?: return null
        val targetPlane = selectedPlane
        if (targetPlane == null && activePlaneSelector.holdsSelection) return null
        val planeResult = surfaceHitTester.hitTestPlaneViewport(
            frame,
            surfaceWidth,
            surfaceHeight,
            columns,
            rows,
            marginX,
            marginY,
            targetPlane,
        )
        if (targetPlane != null || planeResult != null) return planeResult
        return currentDepthSurface()?.let(::serializeDepthSurface)
    }

    fun hitTestTap(x: Float, y: Float): List<HashMap<String, Any>> {
        val frame = latestFrame ?: return emptyList()
        return frame.hitTest(x, y)
            .filter { hit ->
                val trackable = hit.trackable
                (trackable is Plane && trackable.isPoseInPolygon(hit.hitPose)) ||
                    trackable is Point || trackable is DepthPoint
            }
            .map(::serializeHit)
    }

    fun setDepthLocked(locked: Boolean) {
        depthSurfaceTracker.setLocked(locked)
    }

    fun restartPlaneSelection() {
        activePlaneSelector.reset()
        selectedPlane = null
    }

    fun reset() {
        latestFrame = null
        latestDepthSurface = null
        lastDepthScanAtMs = 0L
        lastDepthSurfaceAtMs = 0L
        depthDetectionStreak = 0
        selectedPlane = null
        depthSurfaceTracker.reset()
        activePlaneSelector.reset()
    }

    private fun serializePose(pose: com.google.ar.core.Pose): DoubleArray {
        val matrix = FloatArray(16)
        pose.toMatrix(matrix, 0)
        return DoubleArray(matrix.size) { matrix[it].toDouble() }
    }

    private fun serializeDepthSurface(surface: DepthSurface): HashMap<String, Any> = hashMapOf(
        "rect" to arrayListOf(
            surface.normalizedRect[0].toDouble(),
            surface.normalizedRect[1].toDouble(),
            surface.normalizedRect[2].toDouble(),
            surface.normalizedRect[3].toDouble(),
        ),
        "hits" to ArrayList(surface.corners.map(::serializePose)),
    )

    private fun serializeHit(hit: com.google.ar.core.HitResult): HashMap<String, Any> {
        val type = when (hit.trackable) {
            is Plane -> 1
            is Point -> 2
            is DepthPoint -> 2
            else -> 0
        }
        return hashMapOf(
            "type" to type,
            "distance" to hit.distance.toDouble(),
            "worldTransform" to serializePose(hit.hitPose),
        )
    }

    private fun updateDepthSurface(frame: com.google.ar.core.Frame, depthSupported: Boolean) {
        if (!depthSupported || frame.timestamp == 0L) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastDepthScanAtMs < DEPTH_SCAN_INTERVAL_MS) return
        lastDepthScanAtMs = now
        val detected = depthSurfaceTracker.detect(frame, surfaceWidth, surfaceHeight)
        if (detected != null) {
            latestDepthSurface = detected
            lastDepthSurfaceAtMs = now
            val previousStreak = depthDetectionStreak
            depthDetectionStreak = (depthDetectionStreak + 1).coerceAtMost(REQUIRED_DEPTH_DETECTION_STREAK)
            if (previousStreak < REQUIRED_DEPTH_DETECTION_STREAK &&
                depthDetectionStreak == REQUIRED_DEPTH_DETECTION_STREAK
            ) {
                Log.i(DEPTH_TAG, "Stable low-texture surface acquired")
            }
        } else if (now - lastDepthSurfaceAtMs > DEPTH_SURFACE_TIMEOUT_MS) {
            if (latestDepthSurface != null) Log.i(DEPTH_TAG, "Low-texture surface lost")
            latestDepthSurface = null
            depthDetectionStreak = 0
        }
    }

    private fun currentDepthSurface(): DepthSurface? {
        val surface = latestDepthSurface ?: return null
        return if (SystemClock.elapsedRealtime() - lastDepthSurfaceAtMs <= DEPTH_SURFACE_TIMEOUT_MS) surface else null
    }

    private fun hasMatchingArCorePlane(depthSurface: DepthSurface, planes: Collection<Plane>): Boolean {
        return planes.any { plane ->
            val center = FloatArray(3)
            val normal = FloatArray(3)
            plane.centerPose.getTranslation(center, 0)
            plane.centerPose.getTransformedAxis(1, 1f, normal, 0)
            val planeCenter = Vec3(center[0], center[1], center[2])
            val planeNormal = Vec3(normal[0], normal[1], normal[2]).normalized()
            kotlin.math.abs(planeNormal.dot(depthSurface.plane.normal)) >= MATCHING_PLANE_NORMAL_DOT &&
                kotlin.math.abs((depthSurface.plane.point - planeCenter).dot(planeNormal)) <= MATCHING_PLANE_DISTANCE_METERS
        }
    }

    private companion object {
        const val DEPTH_TAG = "NativeArDepth"
        const val DEPTH_SCAN_INTERVAL_MS = 450L
        const val DEPTH_SURFACE_TIMEOUT_MS = 1600L
        const val REQUIRED_DEPTH_DETECTION_STREAK = 2
        const val MATCHING_PLANE_NORMAL_DOT = 0.92f
        const val MATCHING_PLANE_DISTANCE_METERS = 0.08f
    }
}
