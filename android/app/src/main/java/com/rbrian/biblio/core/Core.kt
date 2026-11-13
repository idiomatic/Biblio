package com.rbrian.biblio.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * The bridge to libbiblio, the Zig core shared with the Apple, GNOME and Windows apps.
 *
 * Each operation is a native method (android/native/src/jni.zig) over the core's typed
 * interface (core/include/biblio.h): it takes strings and numbers, returns this package's
 * model objects, and throws [Failure]. Calls block, so they run on [Dispatchers.IO]. The core
 * paces requests app-wide to stay gentle with library sites. Its HTTP goes through [send], on
 * OkHttp, so the system's and the user's certificate authorities, proxies, and VPNs apply.
 */
object Core {
    init {
        System.loadLibrary("biblio_jni")
        nativeInstallTransport()
    }

    /** One request at a time per call: the core follows redirects and keeps cookies itself. */
    private val http = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * The core's transport (android/native/src/jni.zig): sends one request, [headers] alternating
     * names and values; null if it couldn't be sent.
     */
    @JvmStatic
    fun send(method: String, url: String, headers: Array<String>, body: ByteArray?): HttpResponse? = try {
        val names = Headers.Builder()
        for (i in 0 until headers.size / 2) names.add(headers[2 * i], headers[2 * i + 1])
        // The Content-Type header, if any, stays as the core set it.
        val requestBody = body?.toRequestBody(null) ?: if (method == "POST" || method == "PUT" || method == "PATCH") ByteArray(0).toRequestBody(null) else null
        val request = Request.Builder().url(url).headers(names.build()).method(method, requestBody).build()
        http.newCall(request).execute().use { response ->
            val text = StringBuilder()
            for ((name, value) in response.headers) text.append(name).append(": ").append(value).append("\r\n")
            HttpResponse(response.code, text.toString(), response.body?.bytes() ?: ByteArray(0))
        }
    } catch (e: Exception) {
        null
    }

    @JvmStatic private external fun nativeInstallTransport()
    @JvmStatic private external fun nativeVersion(): String
    @JvmStatic private external fun nativeIncidents(): String?
    @JvmStatic private external fun nativeStatus(client: Long): FetchStatus?
    @JvmStatic private external fun nativeYear(date: String?): String?
    @JvmStatic private external fun nativeHoldStatusRank(status: String?): Int
    @JvmStatic private external fun nativeHoldStatusName(status: String?): String
    @JvmStatic private external fun nativeReadableTint(hex: String, dark: Boolean): String?
    @JvmStatic private external fun nativeFormatCodes(): String

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
    @JvmStatic private external fun nativeBarcode(value: String, code128: Boolean): DoubleArray?
    @JvmStatic private external fun nativeLibraryIcon(website: String?, subdomain: String?, logo: String?): ByteArray?
    @JvmStatic private external fun nativeLogoBounds(pixels: ByteArray, width: Int, height: Int, stride: Int, channels: Int): IntArray?
    @JvmStatic private external fun nativeFormatIsRefined(code: String): Boolean

    @JvmStatic private external fun nativeLogin(client: Long, force: Boolean): Patron
    @JvmStatic private external fun nativePatron(client: Long): Patron?
    @JvmStatic private external fun nativeSearch(
        client: Long, query: String, searchType: String?, filters: Array<String>, page: Int, sort: String?, format: String?,
    ): ListPage
    @JvmStatic private external fun nativeHolds(client: Long, page: Int, sort: String?): ListPage
    @JvmStatic private external fun nativeCheckouts(client: Long, page: Int, sort: String?): ListPage
    @JvmStatic private external fun nativeHistory(client: Long, page: Int, sort: String?): ListPage
    @JvmStatic private external fun nativeHistoryPage(client: Long, page: Int): Long
    @JvmStatic private external fun nativeFreePage(page: Long)
    @JvmStatic private external fun nativeAvailability(client: Long, metadataId: String): List<CopyAvailability>
    @JvmStatic private external fun nativeDetails(client: Long, metadataId: String): DetailList
    @JvmStatic private external fun nativeLocations(client: Long): List<Location>
    @JvmStatic private external fun nativePlaceHold(client: Long, metadataId: String, materialType: String?, pickupBranch: String?)
    @JvmStatic private external fun nativeCancelHolds(client: Long, holds: Array<String>): List<Refusal>
    @JvmStatic private external fun nativeSetPickup(client: Long, branchId: String)
    @JvmStatic private external fun nativeSetLanguage(client: Long, code: String)
    @JvmStatic private external fun nativeSetBorrowingHistory(client: Long, enabled: Boolean)
    @JvmStatic private external fun nativeChangeEmail(client: Long, email: String)
    @JvmStatic private external fun nativeChangePassword(client: Long, current: ByteArray, new: ByteArray)

    @JvmStatic private external fun nativeListNew(kind: Int): Long
    @JvmStatic private external fun nativeListFree(list: Long)
    @JvmStatic private external fun nativeListState(list: Long): IntArray
    @JvmStatic private external fun nativeListGeneration(list: Long): Long
    @JvmStatic private external fun nativeListReload(list: Long, keepContent: Boolean): Long
    @JvmStatic private external fun nativeListBeginRefresh(list: Long)
    @JvmStatic private external fun nativeListClear(list: Long)
    @JvmStatic private external fun nativeListApply(
        list: Long, generation: Long, page: Int, ids: Array<String>, titles: Array<String>, formats: Array<String>,
        libraryFormats: Array<String>, authors: Array<String>, holdStatuses: Array<String>, dates: Array<String>,
        numbers: IntArray, total: Int, pageSize: Int, nowMs: Long,
    ): Boolean
    @JvmStatic private external fun nativeListFail(list: Long, generation: Long, page: Int): Boolean
    @JvmStatic private external fun nativeListRequest(list: Long, page: Int): Boolean
    @JvmStatic private external fun nativeListIsStale(list: Long, nowMs: Long): Boolean
    @JvmStatic private external fun nativeListItemAppeared(list: Long, position: Int): Int
    @JvmStatic private external fun nativeListPlaceholderAppeared(list: Long, position: Int)
    @JvmStatic private external fun nativeListPlaceholderDisappeared(list: Long, position: Int)
    @JvmStatic private external fun nativeListTakeVisibleRequests(list: Long): IntArray
    @JvmStatic private external fun nativeListNeedsAllPages(list: Long): Boolean
    @JvmStatic private external fun nativeListWantsAllPages(list: Long): Boolean
    @JvmStatic private external fun nativeListBeginBackground(list: Long): Boolean
    @JvmStatic private external fun nativeListNextBackgroundPage(list: Long): Int
    @JvmStatic private external fun nativeListEndBackground(list: Long)
    @JvmStatic private external fun nativeListSetSort(list: Long, sort: Int)
    @JvmStatic private external fun nativeListSetFormat(list: Long, format: String?)
    @JvmStatic private external fun nativeListSetHoldFilter(list: Long, filter: Int)
    @JvmStatic private external fun nativeListRemove(list: Long, ids: Array<String>): Int
    @JvmStatic private external fun nativeListHoldCount(list: Long, filter: Int): Int
    @JvmStatic private external fun nativeListRowPositions(list: Long): IntArray
    @JvmStatic private external fun nativeListRowIds(list: Long): String
    @JvmStatic private external fun nativeListFormats(list: Long): String
    @JvmStatic private external fun nativeListFormatFacetCounts(list: Long, values: Array<String>, counts: IntArray): IntArray?
    @JvmStatic private external fun nativeListSetNotBorrowed(list: Long, indexes: LongArray)

    @JvmStatic private external fun nativeBorrowedNew(): Long
    @JvmStatic private external fun nativeBorrowedFree(index: Long)
    @JvmStatic private external fun nativeBorrowedImport(index: Long, bytes: ByteArray): Boolean
    @JvmStatic private external fun nativeBorrowedExport(index: Long): ByteArray?
    @JvmStatic private external fun nativeBorrowedClear(index: Long)
    @JvmStatic private external fun nativeBorrowedBeginSync(index: Long): Int
    @JvmStatic private external fun nativeBorrowedRebuild(index: Long): Int
    @JvmStatic private external fun nativeBorrowedFail(index: Long)
    @JvmStatic private external fun nativeBorrowedApplyPage(index: Long, page: Int, result: Long): Int
    @JvmStatic private external fun nativeBorrowedProgress(index: Long): IntArray
    @JvmStatic private external fun nativeBorrowedGeneration(index: Long): Long
    @JvmStatic private external fun nativeBorrowed(index: Long, metadataId: String, format: String, title: String, author: String?): Borrowed?

    /** A library error, with a message ready to show. Thrown by the native methods. */
    class Failure(val kind: String, message: String, val status: Int? = null) : Exception(message)

    /**
     * The message to show for anything a call threw, [Failure] or not (a closed client, an
     * out-of-memory report), so no failure crashes the app. Cancellation is rethrown: it isn't one.
     */
    fun messageOf(e: Throwable, fallback: String): String {
        if (e is CancellationException) throw e
        return e.message?.takeIf { it.isNotBlank() } ?: fallback
    }

    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }

    /** Keys and values alternating, as the native methods take string maps. */
    private fun Map<String, String>.flattened(): Array<String> = entries.flatMap { listOf(it.key, it.value) }.toTypedArray()

    /** One core client: a (library, username) session, or a guest when [username] is empty. */
    class Client(val subdomain: String, val username: String, password: String?) : AutoCloseable {
        private var handle: Long =
            nativeNewClient(subdomain.encodeToByteArray(), username.encodeToByteArray(), password?.encodeToByteArray())
        private val lock = Any()
        private var inFlight = 0
        private var closing = false
        val isGuest get() = username.isEmpty()

        /** Signs in if needed (always, with [force]) and returns the patron. */
        suspend fun login(force: Boolean = false): Patron = io { h -> nativeLogin(h, force) }

        /** The patron from the last sign-in (no network request). */
        fun patron(): Patron? = call { h -> nativePatron(h) }

        suspend fun search(
            query: String, searchType: String? = null, filters: Map<String, String> = emptyMap(),
            page: Int = 1, sort: String? = null, format: String? = null,
        ): ListPage = io { h -> nativeSearch(h, query, searchType, filters.flattened(), page, sort, format) }

        suspend fun holds(page: Int = 1, sort: String? = null): ListPage = io { h -> nativeHolds(h, page, sort) }
        suspend fun checkouts(page: Int = 1, sort: String? = null): ListPage = io { h -> nativeCheckouts(h, page, sort) }
        suspend fun history(page: Int = 1, sort: String? = null): ListPage = io { h -> nativeHistory(h, page, sort) }

        /** A borrowing history page for [BorrowedIndex.apply]; freed if the caller is canceled meanwhile. */
        suspend fun historyPage(page: Int): HistoryPage {
            var result: HistoryPage? = null
            try {
                withContext(Dispatchers.IO) { result = call { h -> HistoryPage(nativeHistoryPage(h, page)) } }
            } catch (e: CancellationException) {
                result?.close()
                throw e
            }
            return result ?: HistoryPage(0L)
        }

        suspend fun availability(metadataId: String): List<CopyAvailability> = io { h -> nativeAvailability(h, metadataId) }

        /** Full record fields ("Details", "About", …), and which is the edition. */
        suspend fun details(metadataId: String): DetailList = io { h -> nativeDetails(h, metadataId) }

        /** The client's latest request, for the status bar (no network request). */
        fun status(): FetchStatus? = runCatching { call { h -> nativeStatus(h) } }.getOrNull()

        suspend fun locations(): List<Location> = io { h -> nativeLocations(h) }

        /** [pickupBranch] null uses the account's preferred branch. */
        suspend fun placeHold(metadataId: String, materialType: String?, pickupBranch: String?) =
            io { h -> nativePlaceHold(h, metadataId, materialType, pickupBranch) }

        /** Returns the holds the library declined to cancel, with its reasons (often none). */
        suspend fun cancelHolds(holds: List<Hold>): List<Refusal> =
            io { h -> nativeCancelHolds(h, holds.flatMap { listOf(it.id, it.metadataId) }.toTypedArray()) }

        suspend fun setPickup(branchId: String) = io { h -> nativeSetPickup(h, branchId) }
        suspend fun setLanguage(code: String) = io { h -> nativeSetLanguage(h, code) }
        suspend fun setBorrowingHistory(enabled: Boolean) = io { h -> nativeSetBorrowingHistory(h, enabled) }
        suspend fun changeEmail(email: String) = io { h -> nativeChangeEmail(h, email) }

        /** The app must then save the new password (and call [setPassword]). */
        suspend fun changePassword(current: String, new: String) {
            val c = current.encodeToByteArray()
            val n = new.encodeToByteArray()
            try {
                io { h -> nativeChangePassword(h, c, n) }
            } finally {
                c.fill(0)
                n.fill(0)
            }
        }

        /** After a password change, so automatic sign-in keeps working. */
        fun setPassword(password: String) {
            val bytes = password.encodeToByteArray()
            try {
                call { h -> nativeSetPassword(h, bytes) }
            } finally {
                bytes.fill(0)
            }
        }

        /** Runs a blocking native call on the client's handle, which stays valid until the call returns. */
        private fun <T> call(block: (Long) -> T): T {
            val h = synchronized(lock) {
                if (closing || handle == 0L) throw Failure("closed", "The session was closed.")
                inFlight++
                handle
            }
            try {
                return block(h)
            } finally {
                synchronized(lock) {
                    inFlight--
                    if (closing && inFlight == 0) release()
                }
            }
        }

        private suspend fun <T> io(block: (Long) -> T): T = withContext(Dispatchers.IO) { call(block) }

        private fun release() {
            if (handle != 0L) nativeFreeClient(handle)
            handle = 0L
        }

        /** Frees the native client now, or when the last in-flight call returns (a blocking call can't be interrupted). */
        override fun close() {
            synchronized(lock) {
                closing = true
                if (inFlight == 0) release()
            }
        }
    }

    /**
     * The core's item list (core/src/list.zig): which pages to fetch and which rows to show,
     * with sorting and filtering. It makes no requests; the app fetches the pages it asks for and
     * hands them to [apply]. Use one from a single thread (the main thread), as the core requires.
     */
    class CoreList(kind: Kind) : AutoCloseable {
        enum class Kind { Search, Holds, Checkouts, History }
        enum class Sort { Server, PeopleWaiting, Title }

        /** Holds shown by status; [None] shows all. The order matches the core's `biblio_hold_filter`. */
        enum class HoldFilter { None, Ready, NotReady, OnOrder }

        class State(
            val total: Int, val pages: Int, val loaded: Boolean, val hasMore: Boolean,
            val loading: Boolean, val refreshing: Boolean, val generation: Long,
        )

        /** A row: a fetched item's id at a server position, or a placeholder (null id) for one not yet fetched. */
        class Row(val position: Int, val id: String?)

        private var handle = nativeListNew(kind.ordinal)

        fun state(): State = nativeListState(handle).let {
            State(it[0], it[1], it[2] != 0, it[3] != 0, it[4] != 0, it[5] != 0, nativeListGeneration(handle))
        }

        val generation: Long get() = nativeListGeneration(handle)

        /** Starts again from page 1, which it requests; returns the generation to apply results with. */
        fun reload(keepContent: Boolean): Long = nativeListReload(handle, keepContent)
        fun beginRefresh() = nativeListBeginRefresh(handle)
        fun clear() = nativeListClear(handle)

        /** Hands the list a fetched page. False if the list was reloaded since the page was requested. */
        fun apply(generation: Long, page: ListPage, nowMs: Long): Boolean {
            val entries = page.entries
            val numbers = IntArray(3 * entries.size)
            // History sorts by the day each item was borrowed, else returned.
            val dates = Array(entries.size) {
                val e = entries[it]
                e.checkout?.dueDate ?: e.history?.let { h -> h.checkoutDate ?: h.returnedDate } ?: ""
            }
            entries.forEachIndexed { i, e ->
                val onOrder = e.bib.status == "ON_ORDER" || e.bib.onOrderCopies > 0
                numbers[3 * i] = e.bib.heldCopies
                numbers[3 * i + 1] = e.serverIndex
                numbers[3 * i + 2] = (if (e.hold != null) 1 else 0) or (if (e.hold?.isReady == true) 2 else 0) or (if (onOrder) 4 else 0)
            }
            return nativeListApply(
                handle, generation, page.page, Array(entries.size) { entries[it].id }, Array(entries.size) { entries[it].bib.title },
                Array(entries.size) { entries[it].bib.format }, Array(entries.size) { entries[it].bib.libraryFormat },
                Array(entries.size) { entries[it].bib.authors.firstOrNull() ?: "" },
                Array(entries.size) { entries[it].hold?.status ?: "" }, dates,
                numbers, page.count, page.pageSize, nowMs,
            )
        }

        fun fail(generation: Long, page: Int): Boolean = nativeListFail(handle, generation, page)
        fun request(page: Int): Boolean = nativeListRequest(handle, page)
        fun isStale(nowMs: Long): Boolean = nativeListIsStale(handle, nowMs)

        /** An item in view: a page to prefetch, or 0. */
        fun itemAppeared(position: Int): Int = nativeListItemAppeared(handle, position)
        fun placeholderAppeared(position: Int) = nativeListPlaceholderAppeared(handle, position)
        fun placeholderDisappeared(position: Int) = nativeListPlaceholderDisappeared(handle, position)

        /** The pages of placeholders that have stayed on screen briefly; each is then in flight. */
        fun takeVisibleRequests(): List<Int> = nativeListTakeVisibleRequests(handle).toList()

        fun needsAllPages(): Boolean = nativeListNeedsAllPages(handle)
        fun wantsAllPages(): Boolean = nativeListWantsAllPages(handle)
        fun beginBackground(): Boolean = nativeListBeginBackground(handle)

        /** The next page to fetch in the background, or 0 when done. */
        fun nextBackgroundPage(): Int = nativeListNextBackgroundPage(handle)
        fun endBackground() = nativeListEndBackground(handle)

        fun setSort(sort: Sort) = nativeListSetSort(handle, sort.ordinal)

        /** The format filter for account lists, applied locally; null for all. */
        fun setFormat(format: String?) = nativeListSetFormat(handle, format)
        fun setHoldFilter(filter: HoldFilter) = nativeListSetHoldFilter(handle, filter.ordinal)
        fun remove(ids: List<String>): Int = nativeListRemove(handle, ids.toTypedArray())
        fun holdCount(filter: HoldFilter): Int = nativeListHoldCount(handle, filter.ordinal)

        /** "Not Borrowed": hides works these indexes borrowed in the item's format; none turns it off. The indexes must outlive it. */
        fun setNotBorrowed(indexes: List<BorrowedIndex>) = nativeListSetNotBorrowed(handle, LongArray(indexes.size) { indexes[it].handle })

        /** The rows to show, after sorting and filtering. */
        fun rows(): List<Row> {
            val positions = nativeListRowPositions(handle)
            val ids = nativeListRowIds(handle).split('\n')
            return List(positions.size) { Row(positions[it], ids[it].ifEmpty { null }) }
        }

        /** A search's FORMAT facet, with exact counts for refined formats once every item is loaded. */
        fun formatFacet(values: List<FacetValue>): List<FacetValue> {
            if (values.none { it.count < 0 }) return values
            val counts = nativeListFormatFacetCounts(handle, Array(values.size) { values[it].value }, IntArray(values.size) { values[it].count })
                ?: return values
            return values.mapIndexed { i, v -> FacetValue(v.value, counts[i]) }
        }

        /** The loaded items' formats with counts, most common first. */
        fun formats(): List<FacetValue> = nativeListFormats(handle).lineSequence().filter { it.isNotEmpty() }.map {
            val tab = it.lastIndexOf('\t')
            FacetValue(it.substring(0, tab), it.substring(tab + 1).toInt())
        }.toList()

        override fun close() {
            if (handle != 0L) nativeListFree(handle)
            handle = 0L
        }
    }

    /** A borrowing history page as the core holds it, until [BorrowedIndex.apply] takes it or it is closed. */
    class HistoryPage internal constructor(private var pointer: Long) : AutoCloseable {
        internal fun take(): Long = pointer.also { pointer = 0L }

        override fun close() {
            if (pointer != 0L) nativeFreePage(pointer)
            pointer = 0L
        }
    }

    /**
     * What one login borrowed before (core/src/borrowed.zig), from its borrowing history. It makes
     * no requests: a sync asks for history pages, the app fetches each ([Client.historyPage]) and
     * hands it to [apply], which returns the next, 0 when done. Use one from a single thread (the
     * main thread), like [CoreList].
     */
    class BorrowedIndex : AutoCloseable {
        class Progress(val fetched: Int, val total: Int, val complete: Boolean, val syncing: Boolean)

        internal var handle = nativeBorrowedNew()
            private set

        /** False (leaving it empty) if the bytes are unreadable or from another version: sync afresh. */
        fun importBytes(bytes: ByteArray): Boolean = nativeBorrowedImport(handle, bytes)

        /** The bytes to save; null if out of memory. */
        fun exportBytes(): ByteArray? = nativeBorrowedExport(handle)
        fun clear() = nativeBorrowedClear(handle)

        /** The first page to fetch, or 0 if a sync is running. */
        fun beginSync(): Int = nativeBorrowedBeginSync(handle)

        /** Forgets everything and fetches it all again: page 1, or 0 when a running sync starts over instead. */
        fun rebuild(): Int = nativeBorrowedRebuild(handle)
        fun fail() = nativeBorrowedFail(handle)

        /** Hands the index the page it asked for (taking [result]); the next page to fetch, or 0 when done. */
        fun apply(page: Int, result: HistoryPage): Int {
            val pointer = result.take()
            if (pointer == 0L) {
                fail()
                return 0
            }
            return nativeBorrowedApplyPage(handle, page, pointer)
        }

        fun progress(): Progress = nativeBorrowedProgress(handle).let { Progress(it[0], it[1], it[2] != 0, it[3] != 0) }

        /** Changes whenever matches may have. */
        val generation: Long get() = nativeBorrowedGeneration(handle)

        /** Whether the patron borrowed this item, or the same work in another format. */
        fun lookup(bib: Bib): Borrowed? = nativeBorrowed(handle, bib.id, bib.format, bib.title, bib.authors.firstOrNull())

        override fun close() {
            if (handle != 0L) nativeBorrowedFree(handle)
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

    /** The core's version. */
    val version: String by lazy { nativeVersion() }

    /** Server throttling and failures since launch, as JSON, for Copy Diagnostic Log. */
    fun incidents(): String? = nativeIncidents()

    /** "2019" from "c2019.", else the date as given. */
    fun year(date: String?): String? = date?.let { nativeYear(it) }

    /** 0 ready, 1 in transit, 2 waiting, 3 paused. */
    fun holdStatusRank(status: String?): Int = nativeHoldStatusRank(status)

    /** "Ready for pickup", "In transit", "On hold", or "Paused". */
    fun holdStatusName(status: String?): String = nativeHoldStatusName(status)

    /** The brand color ("#RRGGBB") at 4.5:1 contrast with a light or dark bar; null if not a color. */
    fun readableTint(hex: String, dark: Boolean): String? = nativeReadableTint(hex, dark)

    /** The format codes with built-in names, for format pickers. */
    val formatCodes: List<String> by lazy { nativeFormatCodes().lines().filter { it.isNotEmpty() } }

    /** The part of a decoded logo that isn't white margin, as x, y, width, height; null if blank. */
    fun logoBounds(pixels: ByteArray, width: Int, height: Int, stride: Int, channels: Int): IntArray? =
        nativeLogoBounds(pixels, width, height, stride, channels)

    /** "wccls" from "WCCLS", "https://smpl.bibliocommons.com/", …; null if it isn't one. */
    fun subdomainFrom(input: String): String? = nativeSubdomainFrom(input)

    fun formatName(code: String, labels: Map<String, String>): String = nativeFormatName(code, labels.flattened()) ?: code

    fun sortName(id: String, labels: Map<String, String>): String = nativeSortName(id, labels.flattened()) ?: id

    /** A format the core refines from a broader one (4K Ultra HD Blu-ray filed as Blu-ray); searches filter on it locally. */
    fun formatIsRefined(code: String): Boolean = nativeFormatIsRefined(code)

    /** Codabar, or Code 128, bar and space widths in narrow units, bar first; null if [value] can't be encoded. */
    fun barcode(value: String, code128: Boolean = false): DoubleArray? = nativeBarcode(value, code128)
}
