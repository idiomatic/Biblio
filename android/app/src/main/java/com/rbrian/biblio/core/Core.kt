package com.rbrian.biblio.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/**
 * The bridge to libbiblio, the Zig core shared with the Apple, GNOME and Windows apps.
 *
 * Each operation is a native method (android/native/src/jni.zig) over the core's typed
 * interface (core/include/biblio.h): it takes strings and numbers, returns this package's
 * model objects, and throws [Failure]. Calls block, so they run on [Dispatchers.IO]. The core
 * paces requests app-wide to stay gentle with library sites.
 */
object Core {
    init {
        System.loadLibrary("biblio_jni")
    }

    /** For saving [LibraryInfo] (see LibraryStore). */
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }

    @JvmStatic private external fun nativeNewClient(subdomain: ByteArray, username: ByteArray, password: ByteArray?): Long
    @JvmStatic private external fun nativeSetPassword(client: Long, password: ByteArray)
    @JvmStatic private external fun nativeFreeClient(client: Long)

    @JvmStatic private external fun nativeLibraryInfo(subdomain: String): LibraryInfo
    @JvmStatic private external fun nativeDirectoryPage(url: String?): DirectoryPage
    @JvmStatic private external fun nativeResolveSubdomain(name: String, website: String?): String?
    @JvmStatic private external fun nativeSubdomainFrom(input: String): String?
    @JvmStatic private external fun nativeFormatName(code: String, labels: Array<String>): String?
    @JvmStatic private external fun nativeSortName(id: String, labels: Array<String>): String?
    @JvmStatic private external fun nativeCodabar(value: String): DoubleArray?
    @JvmStatic private external fun nativeLibraryIcon(website: String?, subdomain: String?, logo: String?): ByteArray?
    @JvmStatic private external fun nativeLogoBounds(pixels: ByteArray, width: Int, height: Int, stride: Int, channels: Int): IntArray?

    @JvmStatic private external fun nativeLogin(client: Long, force: Boolean): Patron
    @JvmStatic private external fun nativePatron(client: Long): Patron?
    @JvmStatic private external fun nativeSearch(
        client: Long, query: String, searchType: String?, filters: Array<String>, page: Int, sort: String?, format: String?,
    ): ListPage
    @JvmStatic private external fun nativeHolds(client: Long, page: Int, sort: String?): ListPage
    @JvmStatic private external fun nativeCheckouts(client: Long, page: Int, sort: String?): ListPage
    @JvmStatic private external fun nativeHistory(client: Long, page: Int, sort: String?): ListPage
    @JvmStatic private external fun nativeAvailability(client: Long, metadataId: String): List<CopyAvailability>
    @JvmStatic private external fun nativeDetails(client: Long, metadataId: String): List<DetailField>
    @JvmStatic private external fun nativeLocations(client: Long): List<Location>
    @JvmStatic private external fun nativePlaceHold(client: Long, metadataId: String, materialType: String?, pickupBranch: String?)
    @JvmStatic private external fun nativeCancelHolds(client: Long, holds: Array<String>): List<Refusal>
    @JvmStatic private external fun nativeSetPickup(client: Long, branchId: String)
    @JvmStatic private external fun nativeSetLanguage(client: Long, code: String)
    @JvmStatic private external fun nativeSetBorrowingHistory(client: Long, enabled: Boolean)
    @JvmStatic private external fun nativeChangeEmail(client: Long, email: String)
    @JvmStatic private external fun nativeChangePassword(client: Long, current: String, new: String)

    /** A library error, with a message ready to show. Thrown by the native methods. */
    class Failure(val kind: String, message: String, val status: Int? = null) : Exception(message)

    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }

    /** Keys and values alternating, as the native methods take string maps. */
    private fun Map<String, String>.flattened(): Array<String> = entries.flatMap { listOf(it.key, it.value) }.toTypedArray()

    /** One core client: a (library, username) session, or a guest when [username] is empty. */
    class Client(val subdomain: String, val username: String, password: String?) : AutoCloseable {
        private var handle: Long =
            nativeNewClient(subdomain.encodeToByteArray(), username.encodeToByteArray(), password?.encodeToByteArray())
        val isGuest get() = username.isEmpty()

        /** Signs in if needed (always, with [force]) and returns the patron. */
        suspend fun login(force: Boolean = false): Patron = io { nativeLogin(handle, force) }

        /** The patron from the last sign-in (no network request). */
        fun patron(): Patron? = nativePatron(handle)

        suspend fun search(
            query: String, searchType: String? = null, filters: Map<String, String> = emptyMap(),
            page: Int = 1, sort: String? = null, format: String? = null,
        ): ListPage = io { nativeSearch(handle, query, searchType, filters.flattened(), page, sort, format) }

        suspend fun holds(page: Int = 1, sort: String? = null): ListPage = io { nativeHolds(handle, page, sort) }
        suspend fun checkouts(page: Int = 1, sort: String? = null): ListPage = io { nativeCheckouts(handle, page, sort) }
        suspend fun history(page: Int = 1, sort: String? = null): ListPage = io { nativeHistory(handle, page, sort) }

        suspend fun availability(metadataId: String): List<CopyAvailability> = io { nativeAvailability(handle, metadataId) }

        /** Full record fields ("Details", "About", …). */
        suspend fun details(metadataId: String): List<DetailField> = io { nativeDetails(handle, metadataId) }

        suspend fun locations(): List<Location> = io { nativeLocations(handle) }

        /** [pickupBranch] null uses the account's preferred branch. */
        suspend fun placeHold(metadataId: String, materialType: String?, pickupBranch: String?) =
            io { nativePlaceHold(handle, metadataId, materialType, pickupBranch) }

        /** Returns the holds the library declined to cancel, with its reasons (often none). */
        suspend fun cancelHolds(holds: List<Hold>): List<Refusal> =
            io { nativeCancelHolds(handle, holds.flatMap { listOf(it.id, it.metadataId) }.toTypedArray()) }

        suspend fun setPickup(branchId: String) = io { nativeSetPickup(handle, branchId) }
        suspend fun setLanguage(code: String) = io { nativeSetLanguage(handle, code) }
        suspend fun setBorrowingHistory(enabled: Boolean) = io { nativeSetBorrowingHistory(handle, enabled) }
        suspend fun changeEmail(email: String) = io { nativeChangeEmail(handle, email) }

        /** The app must then save the new password (and call [setPassword]). */
        suspend fun changePassword(current: String, new: String) = io { nativeChangePassword(handle, current, new) }

        /** After a password change, so automatic sign-in keeps working. */
        fun setPassword(password: String) = nativeSetPassword(handle, password.encodeToByteArray())

        override fun close() {
            if (handle != 0L) nativeFreeClient(handle)
            handle = 0L
        }
    }

    // Library operations (no account)

    /** Name, brand color, languages and catalog labels from the library's public search page. */
    suspend fun libraryInfo(subdomain: String): LibraryInfo = io { nativeLibraryInfo(subdomain) }

    /** A page of BiblioCommons' partner directory: [url] null for the first, then each page's next. */
    suspend fun directoryPage(url: String?): DirectoryPage = io { nativeDirectoryPage(url) }

    /** Guesses and confirms a directory entry's catalog subdomain. */
    suspend fun resolveSubdomain(name: String, website: String?): String? = io { nativeResolveSubdomain(name, website) }

    /** A library's icon (PNG, ICO, GIF, BMP or JPEG bytes), or null. [website] null reads it from [subdomain]'s catalog. */
    class LibraryIcon(val isLogo: Boolean, val bytes: ByteArray)

    suspend fun libraryIcon(website: String?, subdomain: String?, logo: String?): LibraryIcon? = io {
        nativeLibraryIcon(website, subdomain, logo)?.let { LibraryIcon(it[0].toInt() == 2, it.copyOfRange(1, it.size)) }
    }

    // Display helpers (no network)

    /** The part of a decoded logo that isn't white margin, as x, y, width, height; null if blank. */
    fun logoBounds(pixels: ByteArray, width: Int, height: Int, stride: Int, channels: Int): IntArray? =
        nativeLogoBounds(pixels, width, height, stride, channels)

    /** "wccls" from "WCCLS", "https://smpl.bibliocommons.com/", …; null if it isn't one. */
    fun subdomainFrom(input: String): String? = nativeSubdomainFrom(input)

    fun formatName(code: String, labels: Map<String, String>): String = nativeFormatName(code, labels.flattened()) ?: code

    fun sortName(id: String, labels: Map<String, String>): String = nativeSortName(id, labels.flattened()) ?: id

    /** Codabar bar and space widths in narrow units, bar first; null if [value] can't be encoded. */
    fun codabar(value: String): DoubleArray? = nativeCodabar(value)
}
