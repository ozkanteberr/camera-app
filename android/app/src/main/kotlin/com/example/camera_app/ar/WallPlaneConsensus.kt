package com.example.camera_app.ar

import kotlin.math.abs

/** Selects one temporally repeated vertical plane before it can become stable. */
internal class WallPlaneConsensus {
    private val history = ArrayList<WallObservation>(MAX_HISTORY)
    private var committedPlane: DepthPlane? = null

    fun observe(observations: List<WallObservation>, nowMs: Long): WallConsensusResult? {
        history.removeAll { nowMs - it.observedAtMs > HISTORY_WINDOW_MS }
        history.addAll(observations)
        while (history.size > MAX_HISTORY) history.removeAt(0)
        if (observations.isEmpty()) return null

        committedPlane?.let { plane ->
            val compatible = observations.filter { isCompatible(plane, it.surface.plane) }
            if (compatible.isEmpty()) return null
            val chosen = preferred(compatible)
            return WallConsensusResult(
                chosen.copy(surface = chosen.surface.copy(plane = plane)),
                stable = true,
                confirmationFrames = REQUIRED_CONFIRMATION_FRAMES,
            )
        }
        if (history.isEmpty()) return null

        val cluster = history.map { seed ->
            history.filter { isCompatible(seed.surface.plane, it.surface.plane) }
        }.maxWithOrNull(
            compareBy<List<WallObservation>> { distinctFrames(it) }
                .thenBy { it.sumOf { item -> sourceWeight(item.source) } }
                .thenBy { it.maxOfOrNull(::rectArea) ?: 0f },
        ) ?: return null
        val confirmations = distinctFrames(cluster)
        val clusterReference = preferred(cluster)
        val consensusPlane = averagePlane(cluster, clusterReference.surface.plane.normal)
        val currentCandidates = observations.filter {
            isCompatible(consensusPlane, it.surface.plane)
        }
        if (currentCandidates.isEmpty()) return null
        val chosen = preferred(currentCandidates)
        val stable = confirmations >= REQUIRED_CONFIRMATION_FRAMES
        if (stable) committedPlane = consensusPlane
        return WallConsensusResult(
            chosen.copy(surface = chosen.surface.copy(plane = consensusPlane)),
            stable,
            confirmations,
        )
    }

    fun reset() {
        history.clear()
        committedPlane = null
    }

    private fun averagePlane(observations: List<WallObservation>, referenceNormal: Vec3): DepthPlane {
        var pointSum = Vec3(0f, 0f, 0f)
        var normalSum = Vec3(0f, 0f, 0f)
        for (observation in observations) {
            pointSum += observation.surface.plane.point
            var normal = observation.surface.plane.normal.verticalized()
            if (normal.dot(referenceNormal) < 0f) normal *= -1f
            normalSum += normal
        }
        return DepthPlane(
            pointSum * (1f / observations.size),
            normalSum.normalized().verticalized(),
        )
    }

    private fun preferred(observations: List<WallObservation>): WallObservation =
        observations.maxWith(
            compareBy<WallObservation> { it.observedAtMs }
                .thenBy { sourceWeight(it.source) }
                .thenBy(::rectArea),
        )

    private fun distinctFrames(observations: List<WallObservation>): Int =
        observations.map(WallObservation::observedAtMs).distinct().size

    private fun rectArea(observation: WallObservation): Float {
        val rect = observation.surface.normalizedRect
        return if (rect.size == 4) (rect[2] - rect[0]) * (rect[3] - rect[1]) else 0f
    }

    private fun sourceWeight(source: WallObservationSource): Int = when (source) {
        WallObservationSource.DEPTH_PATCH -> 3
        WallObservationSource.FEATURE_POINTS -> 2
        WallObservationSource.ARCORE_PLANE -> 1
    }

    private fun isCompatible(first: DepthPlane, second: DepthPlane): Boolean =
        abs(first.normal.verticalized().dot(second.normal.verticalized())) >= NORMAL_DOT &&
            abs((second.point - first.point).dot(first.normal.verticalized())) <= DISTANCE_METERS

    private companion object {
        const val MAX_HISTORY = 14
        const val HISTORY_WINDOW_MS = 1800L
        const val REQUIRED_CONFIRMATION_FRAMES = 3
        const val NORMAL_DOT = 0.90f
        const val DISTANCE_METERS = 0.12f
    }
}
