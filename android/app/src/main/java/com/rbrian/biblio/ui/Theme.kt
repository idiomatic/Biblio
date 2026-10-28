package com.rbrian.biblio.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/** Material 3 with the wallpaper's dynamic colors. */
@Composable
fun BiblioTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val colors = if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    MaterialTheme(colorScheme = colors, content = content)
}

/** Copy-status colors; text and icons always state the status too. */
object StatusColors {
    @Composable
    fun copy(kind: String): Color {
        val dark = isSystemInDarkTheme()
        fun pick(light: Long, darkColor: Long) = Color(if (dark) darkColor else light)
        return when (kind) {
            "available" -> pick(0xFF1B7F3B, 0xFF7BD88F)
            "onOrder" -> pick(0xFF00796B, 0xFF6FD6C8)
            "out", "other" -> pick(0xFFB25E00, 0xFFFFB86B)
            "held" -> pick(0xFF7B3FA0, 0xFFD3A6F2)
            "transit" -> pick(0xFF3F51B5, 0xFFA9B4FF)
            "repair" -> pick(0xFF795548, 0xFFD7B19D)
            "missing", "claimsReturned" -> MaterialTheme.colorScheme.error
            else -> MaterialTheme.colorScheme.onSurfaceVariant
        }
    }

    @Composable
    fun availability(status: String?): Color = when (status) {
        "AVAILABLE" -> copy("available")
        "ON_ORDER" -> copy("onOrder")
        "UNAVAILABLE", "NOT_AVAILABLE" -> copy("out")
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
}
