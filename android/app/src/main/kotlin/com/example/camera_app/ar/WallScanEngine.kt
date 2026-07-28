package com.example.camera_app.ar

import android.util.Log
import com.google.ar.core.Camera
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Session

/** Owns every mutable selector and tracking state used by wall/cabinet mode. */
internal class WallScanEngine {
    private val planeSelector = ArActivePlaneSelector()
    private val surfaceTracker = WallSurfaceTracker()
    private val depthProvider = WallDepthProbeProvider()
    private val featurePointProvider = WallFeaturePointPlaneProvider()
    private val consensus = WallPlaneConsensus()
    private val geometry = WallSurfaceGeometry()
    private var lastDiagnostic = ""
    private var lastDiagnosticAtMs = 0L
    private var lastObservationAtMs = 0L
    private var lastConsensusResult: WallConsensusResult? = null

    fun update(
        frame: Frame,
        trackedPlanes: List<Plane>,
        width: Int,
        height: Int,
        nowMs: Long,
        depthSupported: Boolean,
    ): WallSurfaceUpdate {
        val verticalPlanes = trackedPlanes.filter { it.type == Plane.Type.VERTICAL }
        val current = surfaceTracker.advance(nowMs)
        if (current.state == WallSurfaceState.LOCKED ||
            nowMs - lastObservationAtMs < OBSERVATION_INTERVAL_MS
        ) {
            reportDiagnostics(current, lastConsensusResult, depthSupported, verticalPlanes.size, nowMs)
            return current
        }
        lastObservationAtMs = nowMs
        val observations = ArrayList<WallObservation>(3)
        depthProvider.observe(frame, width, height, nowMs, depthSupported)?.let(observations::add)
        featurePointProvider.observe(frame, nowMs)?.let(observations::add)
        val fallbackPlane = planeSelector.select(frame, verticalPlanes, width, height, nowMs)
        if (fallbackPlane != null) {
            geometry.fromPlane(fallbackPlane)?.let { surface ->
                observations.add(
                    WallObservation(surface, WallObservationSource.ARCORE_PLANE, nowMs),
                )
            }
        }
        val result = consensus.observe(observations, nowMs)
        lastConsensusResult = result
        val update = if (result == null) {
            surfaceTracker.advance(nowMs)
        } else {
            surfaceTracker.observeSurface(
                result.observation.surface,
                result.observation.observedAtMs,
                result.stable,
            )
        }
        reportDiagnostics(update, result, depthSupported, verticalPlanes.size, nowMs)
        return update
    }

    fun lock(session: Session): Boolean = surfaceTracker.lock(session)

    fun unlock() = surfaceTracker.unlock()

    fun renderUpdate(nowMs: Long): WallSurfaceUpdate = surfaceTracker.renderUpdate(nowMs)

    fun visibleSurface(camera: Camera, width: Int, height: Int): DepthSurface? =
        surfaceTracker.visibleSurface(camera, width, height)

    fun restartSelection() {
        planeSelector.reset()
    }

    fun reset() {
        planeSelector.reset()
        surfaceTracker.reset()
        depthProvider.reset()
        featurePointProvider.reset()
        consensus.reset()
        lastDiagnostic = ""
        lastDiagnosticAtMs = 0L
        lastObservationAtMs = 0L
        lastConsensusResult = null
    }

    private fun reportDiagnostics(
        update: WallSurfaceUpdate,
        result: WallConsensusResult?,
        depthSupported: Boolean,
        verticalPlaneCount: Int,
        nowMs: Long,
    ) {
        val source = result?.observation?.source?.name ?: "NONE"
        val confirmations = result?.confirmationFrames ?: 0
        val diagnostic = "state=${update.state.wireValue} depth=$depthSupported " +
            "probe=${depthProvider.diagnostic} features=${featurePointProvider.diagnostic} " +
            "source=$source confirmations=$confirmations " +
            "verticalPlanes=$verticalPlaneCount surface=${update.surface != null}"
        if (diagnostic == lastDiagnostic && nowMs - lastDiagnosticAtMs < LOG_INTERVAL_MS) return
        lastDiagnostic = diagnostic
        lastDiagnosticAtMs = nowMs
        Log.i(TAG, diagnostic)
    }

    private companion object {
        const val TAG = "WallScanEngine"
        const val LOG_INTERVAL_MS = 2000L
        const val OBSERVATION_INTERVAL_MS = 280L
    }
}
