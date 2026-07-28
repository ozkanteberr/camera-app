package com.example.camera_app.ar

import android.util.Log
import com.google.ar.core.Camera
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import kotlin.math.abs

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
                    WallObservation(
                        surface,
                        WallObservationSource.ARCORE_PLANE,
                        nowMs,
                        ARCORE_PLANE_CONFIDENCE,
                    ),
                )
            }
        }
        val result = consensus.observe(observations, nowMs)
        lastConsensusResult = result
        val update = if (result == null) {
            surfaceTracker.advance(nowMs)
        } else {
            val observedSurface = growthSurface(frame, width, height, result)
            surfaceTracker.observeSurface(
                observedSurface,
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

    private fun growthSurface(
        frame: Frame,
        width: Int,
        height: Int,
        result: WallConsensusResult,
    ): DepthSurface {
        val observation = result.observation
        if (!result.stable || !supportsFocusedGrowth(frame, width, height, observation)) {
            return observation.surface
        }
        val footprint = geometry.fromViewRect(
            frame.camera,
            FOCUS_GROWTH_RECT,
            observation.surface.plane,
        ) ?: return observation.surface
        return observation.surface.copy(
            corners = observation.surface.corners + footprint.corners,
        )
    }

    private fun supportsFocusedGrowth(
        frame: Frame,
        width: Int,
        height: Int,
        observation: WallObservation,
    ): Boolean = when (observation.source) {
        WallObservationSource.DEPTH_PATCH,
        WallObservationSource.FEATURE_POINTS -> containsFocus(observation.surface.normalizedRect)
        WallObservationSource.ARCORE_PLANE -> hasFocusedPlaneHit(
            frame,
            width,
            height,
            observation.surface.plane,
        )
    }

    private fun hasFocusedPlaneHit(
        frame: Frame,
        width: Int,
        height: Int,
        expected: DepthPlane,
    ): Boolean {
        if (width <= 0 || height <= 0) return false
        return frame.hitTest(width * FOCUS_CENTER, height * FOCUS_CENTER).any { hit ->
            val plane = hit.trackable as? Plane ?: return@any false
            if (plane.type != Plane.Type.VERTICAL ||
                plane.trackingState != TrackingState.TRACKING ||
                !plane.isPoseInPolygon(hit.hitPose)
            ) {
                return@any false
            }
            val observed = geometry.fromPlane(plane)?.plane ?: return@any false
            planesMatch(expected, observed)
        }
    }

    private fun containsFocus(rect: FloatArray): Boolean = rect.size == 4 &&
        rect[0] <= FOCUS_CENTER && rect[2] >= FOCUS_CENTER &&
        rect[1] <= FOCUS_CENTER && rect[3] >= FOCUS_CENTER

    private fun planesMatch(first: DepthPlane, second: DepthPlane): Boolean {
        val firstNormal = first.normal.verticalized()
        val secondNormal = second.normal.verticalized()
        return abs(firstNormal.dot(secondNormal)) >= GROWTH_NORMAL_DOT &&
            abs((second.point - first.point).dot(firstNormal)) <= GROWTH_DISTANCE_METERS
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
        val confidence = ((result?.observation?.confidence ?: 0f) * 100f).toInt()
        val agreement = ((result?.normalAgreement ?: 0f) * 100f).toInt()
        val diagnostic = "state=${update.state.wireValue} depth=$depthSupported " +
            "probe=${depthProvider.diagnostic} features=${featurePointProvider.diagnostic} " +
            "source=$source confidence=$confidence agreement=$agreement confirmations=$confirmations " +
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
        const val ARCORE_PLANE_CONFIDENCE = 0.97f
        const val FOCUS_CENTER = 0.5f
        const val GROWTH_NORMAL_DOT = 0.97f
        const val GROWTH_DISTANCE_METERS = 0.09f
        val FOCUS_GROWTH_RECT = floatArrayOf(0.40f, 0.38f, 0.60f, 0.62f)
    }
}
