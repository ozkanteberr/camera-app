package com.example.camera_app.ar

internal enum class WallObservationSource {
    DEPTH_PATCH,
    FEATURE_POINTS,
    ARCORE_PLANE,
}

internal data class WallObservation(
    val surface: DepthSurface,
    val source: WallObservationSource,
    val observedAtMs: Long,
    val confidence: Float,
)

internal data class WallConsensusResult(
    val observation: WallObservation,
    val stable: Boolean,
    val confirmationFrames: Int,
    val normalAgreement: Float,
)
