package com.example.camera_app.ar

import android.app.Activity
import android.view.Surface
import com.google.ar.core.Config

internal fun planeFindingModeFor(index: Int): Config.PlaneFindingMode = when (index) {
    0 -> Config.PlaneFindingMode.DISABLED
    1 -> Config.PlaneFindingMode.HORIZONTAL
    2 -> Config.PlaneFindingMode.VERTICAL
    else -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
}

@Suppress("DEPRECATION")
internal fun Activity.displayRotation(): Int =
    windowManager.defaultDisplay?.rotation ?: Surface.ROTATION_0
