package com.example.camera_app.ar

import kotlin.math.abs

/** Refines a visible preview, then freezes only a tightly agreeing vertical plane. */
internal class WallPlaneConsensus {
    private val history = ArrayList<WallObservation>(MAX_HISTORY)
    private var committedPlane: DepthPlane? = null

    fun observe(observations: List<WallObservation>, nowMs: Long): WallConsensusResult? {
        history.removeAll { nowMs - it.observedAtMs > HISTORY_WINDOW_MS }
        history.addAll(observations)
        while (history.size > MAX_HISTORY) history.removeAt(0)
        if (observations.isEmpty()) return null

        committedPlane?.let { plane ->
            val compatible = observations.filter {
                isCompatible(
                    plane,
                    it.surface.plane,
                    COMMITTED_NORMAL_DOT,
                    COMMITTED_DISTANCE_METERS,
                )
            }
            if (compatible.isEmpty()) return null
            val chosen = preferred(compatible)
            return WallConsensusResult(
                chosen.copy(surface = chosen.surface.copy(plane = plane)),
                stable = true,
                confirmationFrames = requiredFrames(compatible),
                normalAgreement = normalAgreement(compatible, plane),
            )
        }

        val cluster = history.map { seed ->
            history.filter {
                isCompatible(
                    seed.surface.plane,
                    it.surface.plane,
                    PREVIEW_NORMAL_DOT,
                    PREVIEW_DISTANCE_METERS,
                )
            }
        }.maxWithOrNull(
            compareBy<List<WallObservation>> { distinctFrames(it) }
                .thenBy { observationWeight(it) }
                .thenBy { it.maxOfOrNull(::rectArea) ?: 0f },
        ) ?: return null
        val clusterReference = preferred(cluster)
        val previewPlane = averagePlane(cluster, clusterReference.surface.plane.normal)
        val currentCandidates = observations.filter {
            isCompatible(
                previewPlane,
                it.surface.plane,
                PREVIEW_NORMAL_DOT,
                PREVIEW_DISTANCE_METERS,
            )
        }
        if (currentCandidates.isEmpty()) return null

        val tightCluster = history.filter {
            isCompatible(
                previewPlane,
                it.surface.plane,
                LOCK_NORMAL_DOT,
                LOCK_DISTANCE_METERS,
            )
        }
        val confirmations = distinctFrames(tightCluster)
        val agreement = normalAgreement(tightCluster, previewPlane)
        val stable = canCommit(tightCluster, agreement)
        val finalPlane = if (stable) {
            averagePlane(tightCluster, previewPlane.normal).also { committedPlane = it }
        } else {
            previewPlane
        }
        val chosen = preferred(currentCandidates)
        return WallConsensusResult(
            chosen.copy(surface = chosen.surface.copy(plane = finalPlane)),
            stable,
            confirmations,
            agreement,
        )
    }

    fun reset() {
        history.clear()
        committedPlane = null
    }

    private fun averagePlane(observations: List<WallObservation>, referenceNormal: Vec3): DepthPlane {
        var pointSum = Vec3(0f, 0f, 0f)
        var normalSum = Vec3(0f, 0f, 0f)
        var totalWeight = 0f
        for (observation in observations) {
            val weight = itemWeight(observation)
            pointSum += observation.surface.plane.point * weight
            var normal = observation.surface.plane.normal.verticalized()
            if (normal.dot(referenceNormal) < 0f) normal *= -1f
            normalSum += normal * weight
            totalWeight += weight
        }
        return DepthPlane(
            pointSum * (1f / totalWeight.coerceAtLeast(1e-5f)),
            normalSum.normalized().verticalized(),
        )
    }

    private fun preferred(observations: List<WallObservation>): WallObservation =
        observations.maxWith(
            compareBy<WallObservation> { it.observedAtMs }
                .thenBy(::itemWeight)
                .thenBy(::rectArea),
        )

    private fun canCommit(observations: List<WallObservation>, agreement: Float): Boolean {
        if (observations.isEmpty() || agreement < LOCK_NORMAL_DOT) return false
        val frames = distinctFrames(observations)
        if (frames < requiredFrames(observations)) return false
        val firstAt = observations.minOf(WallObservation::observedAtMs)
        val lastAt = observations.maxOf(WallObservation::observedAtMs)
        val reliableSource = observations.any { it.source != WallObservationSource.FEATURE_POINTS }
        val requiredDuration = if (reliableSource) RELIABLE_LOCK_DURATION_MS else FEATURE_LOCK_DURATION_MS
        if (lastAt - firstAt < requiredDuration) return false
        return reliableSource || weightedConfidence(observations) >= MIN_FEATURE_LOCK_CONFIDENCE
    }

    private fun requiredFrames(observations: List<WallObservation>): Int =
        if (observations.any { it.source != WallObservationSource.FEATURE_POINTS }) {
            RELIABLE_CONFIRMATION_FRAMES
        } else {
            FEATURE_CONFIRMATION_FRAMES
        }

    private fun normalAgreement(observations: List<WallObservation>, plane: DepthPlane): Float {
        if (observations.isEmpty()) return 0f
        var score = 0f
        var weight = 0f
        for (observation in observations) {
            val itemWeight = itemWeight(observation)
            score += abs(observation.surface.plane.normal.verticalized().dot(plane.normal)) * itemWeight
            weight += itemWeight
        }
        return score / weight.coerceAtLeast(1e-5f)
    }

    private fun weightedConfidence(observations: List<WallObservation>): Float {
        val weight = observations.sumOf { sourceWeight(it.source).toDouble() }.toFloat()
        val score = observations.sumOf {
            (it.confidence * sourceWeight(it.source)).toDouble()
        }.toFloat()
        return score / weight.coerceAtLeast(1e-5f)
    }

    private fun observationWeight(observations: List<WallObservation>): Float =
        observations.sumOf { itemWeight(it).toDouble() }.toFloat()

    private fun itemWeight(observation: WallObservation): Float =
        sourceWeight(observation.source) * observation.confidence.coerceIn(0.1f, 1f)

    private fun distinctFrames(observations: List<WallObservation>): Int =
        observations.map(WallObservation::observedAtMs).distinct().size

    private fun rectArea(observation: WallObservation): Float {
        val rect = observation.surface.normalizedRect
        return if (rect.size == 4) (rect[2] - rect[0]) * (rect[3] - rect[1]) else 0f
    }

    private fun sourceWeight(source: WallObservationSource): Float = when (source) {
        WallObservationSource.DEPTH_PATCH -> 1.35f
        WallObservationSource.ARCORE_PLANE -> 1.10f
        WallObservationSource.FEATURE_POINTS -> 0.75f
    }

    private fun isCompatible(
        first: DepthPlane,
        second: DepthPlane,
        normalDot: Float,
        distanceMeters: Float,
    ): Boolean = abs(first.normal.verticalized().dot(second.normal.verticalized())) >= normalDot &&
        abs((second.point - first.point).dot(first.normal.verticalized())) <= distanceMeters

    private companion object {
        const val MAX_HISTORY = 24
        const val HISTORY_WINDOW_MS = 2600L
        const val RELIABLE_CONFIRMATION_FRAMES = 4
        const val FEATURE_CONFIRMATION_FRAMES = 5
        const val RELIABLE_LOCK_DURATION_MS = 700L
        const val FEATURE_LOCK_DURATION_MS = 1050L
        const val MIN_FEATURE_LOCK_CONFIDENCE = 0.62f
        const val PREVIEW_NORMAL_DOT = 0.92f
        const val PREVIEW_DISTANCE_METERS = 0.12f
        const val LOCK_NORMAL_DOT = 0.990f
        const val LOCK_DISTANCE_METERS = 0.065f
        const val COMMITTED_NORMAL_DOT = 0.97f
        const val COMMITTED_DISTANCE_METERS = 0.09f
    }
}
