package com.example.camera_app.ar

internal enum class ArSurfaceScanMode {
    SHELF,
    WALL,
    ;

    companion object {
        fun fromWireValue(value: String?): ArSurfaceScanMode =
            if (value == "wall") WALL else SHELF
    }
}
