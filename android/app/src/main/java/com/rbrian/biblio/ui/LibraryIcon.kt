package com.rbrian.biblio.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocalLibrary
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.foundation.isSystemInDarkTheme
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.rbrian.biblio.core.DirectoryEntry
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.core.Core
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URLEncoder
import java.nio.ByteBuffer

/**
 * Library icons from the core, cached on disk so each library's site is asked only once.
 * A wide directory logo is trimmed to its content and fitted on white.
 */
object LibraryIcons {
    class Icon(val bitmap: ImageBitmap, val isLogo: Boolean)

    /** Null once a lookup found nothing (asked again next launch). */
    private val icons = mutableStateMapOf<String, Icon?>()
    private val started = mutableSetOf<String>()

    /** Icons are keyed by website host, so a directory suggestion and the added library share one. */
    fun key(website: String?, fallback: String): String =
        website?.let { Uri.parse(if ("://" in it) it else "https://$it").host?.lowercase() } ?: fallback

    fun icon(key: String): Icon? = icons[key]

    suspend fun load(cache: File, key: String, website: String?, subdomain: String?, logo: String?) {
        if (!started.add(key)) return
        val name = URLEncoder.encode(key, "UTF-8")
        val square = File(cache, "$name.icon")
        val wide = File(cache, "$name.logo")
        val icon = withContext(Dispatchers.IO) {
            listOf(square to false, wide to true).firstNotNullOfOrNull { (file, isLogo) ->
                if (file.exists()) decode(file.readBytes(), isLogo) else null
            } ?: Core.libraryIcon(website, subdomain, logo)?.let { found ->
                decode(found.bytes, found.isLogo)?.also {
                    cache.mkdirs()
                    (if (found.isLogo) wide else square).writeBytes(found.bytes)
                }
            }
        }
        icons[key] = icon
    }

    private fun decode(bytes: ByteArray, isLogo: Boolean): Icon? {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        return Icon((if (isLogo) trimmed(bitmap) else bitmap).asImageBitmap(), isLogo)
    }

    private fun trimmed(bitmap: Bitmap): Bitmap {
        val argb = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
        val pixels = ByteBuffer.allocate(argb.byteCount).also(argb::copyPixelsToBuffer).array()
        val (x, y, w, h) = Core.logoBounds(pixels, argb.width, argb.height, argb.rowBytes, 4) ?: return bitmap
        return Bitmap.createBitmap(argb, x, y, w, h)
    }
}

/** A square library icon, or a tile in the library's brand color. */
@Composable
fun LibraryIcon(
    key: String, website: String?, subdomain: String? = null, logo: String? = null,
    tint: Color = MaterialTheme.colorScheme.primary, size: Dp = 40.dp,
) {
    val cache = File(LocalContext.current.cacheDir, "LibraryIcons")
    LaunchedEffect(key) { LibraryIcons.load(cache, key, website, subdomain, logo) }
    val shape = RoundedCornerShape(size * 0.22f)
    val icon = LibraryIcons.icon(key)
    Box(
        Modifier.size(size).clip(shape)
            .background(if (icon == null) tint else Color.White)
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, shape),
        contentAlignment = Alignment.Center,
    ) {
        when {
            icon == null -> Icon(Icons.Filled.LocalLibrary, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.5f))
            icon.isLogo -> Image(icon.bitmap, null, Modifier.padding(size * 0.08f), contentScale = ContentScale.Fit)
            else -> Image(icon.bitmap, null, Modifier.size(size), contentScale = ContentScale.Crop)
        }
    }
}

/** The library's brand color at 4.5:1 contrast with the current theme's bars, from the core; null if it has none. */
@Composable
fun brandTint(hex: String?): Color? {
    val dark = isSystemInDarkTheme()
    return remember(hex, dark) {
        hex?.let { Core.readableTint(it, dark) }?.removePrefix("#")?.takeIf { it.length == 6 }?.toLongOrNull(16)
            ?.let { Color(0xFF000000 or it) }
    }
}

/** Library names and logos from BiblioCommons' partner directory, fetched once for the app's life. */
object DirectoryCache {
    val entries = mutableStateListOf<DirectoryEntry>()
    private val lock = Mutex()
    private var complete = false

    /** Pages through the directory unless an earlier call did; a failed fetch is tried again by the next call. */
    suspend fun load() {
        lock.withLock {
            if (complete) return@withLock
            var next: String? = null
            val seen = entries.mapTo(mutableSetOf()) { it.name }
            do {
                val url = next
                val page = try {
                    Core.directoryPage(url)
                } catch (e: Exception) {
                    Core.messageOf(e, "")
                    return@withLock
                }
                val fresh = page.entries.filter { seen.add(it.name) }
                entries += fresh
                next = page.next
            } while (next != null && fresh.isNotEmpty())
            complete = true
        }
    }
}
