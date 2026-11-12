package com.rbrian.biblio.ui

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.rbrian.biblio.core.AccountStatus
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.FacetValue
import com.rbrian.biblio.core.Hold
import com.rbrian.biblio.core.LibraryInfo
import com.rbrian.biblio.core.ListEntry
import com.rbrian.biblio.core.ListPage
import com.rbrian.biblio.core.Location
import com.rbrian.biblio.core.Patron
import com.rbrian.biblio.data.LibraryStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class Section(val title: String) {
    Search("Search"), NewTitles("New Titles"), Holds("Holds"), Checkouts("Checked Out"), History("Borrowing History"), Account("Account")
}

/** One signed-in account (or a guest): its core client, patron and lists. */
class Session(val library: LibraryInfo, val username: String, val store: LibraryStore) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val client = Core.Client(library.subdomain, username, if (username.isEmpty()) null else store.password(library.subdomain, username))
    val isGuest get() = username.isEmpty()

    var patron by mutableStateOf<Patron?>(null)
    var locations by mutableStateOf<List<Location>>(emptyList())
    var message by mutableStateOf<String?>(null)
    var signInError by mutableStateOf<String?>(null)

    val search = ItemList(this, Section.Search)
    val newTitles = ItemList(this, Section.NewTitles, defaultSort = "newly_acquired")
    val holds = ItemList(this, Section.Holds)
    val checkouts = ItemList(this, Section.Checkouts)
    val history = ItemList(this, Section.History)

    /** What this account borrowed before, from its borrowing history; null for guests. */
    val borrowed = if (isGuest) null else BorrowedHistory(this)

    fun list(section: Section) = when (section) {
        Section.Search -> search
        Section.NewTitles -> newTitles
        Section.Holds -> holds
        Section.Checkouts -> checkouts
        Section.History -> history
        Section.Account -> null
    }

    init {
        scope.launch {
            locations = runCatching { client.locations() }.getOrDefault(emptyList())
        }
        if (!isGuest) scope.launch {
            try {
                patron = client.login()
                // Fill the hold and checkout counts without waiting for those lists to be opened.
                holds.loadIfNeeded()
                checkouts.loadIfNeeded()
                borrowed?.start(patron?.borrowingHistoryEnabled)
            } catch (e: Core.Failure) {
                signInError = e.message
            }
        }
    }

    fun close() {
        scope.coroutineContext[Job]?.cancel()
        for (l in listOf(search, newTitles, holds, checkouts, history)) l.close()
        borrowed?.close()
        client.close()
    }

    fun refreshPatron() {
        patron = runCatching { client.patron() }.getOrNull() ?: patron
        if (patron?.borrowingHistoryEnabled == false) borrowed?.clear()
    }

    /** The borrowed-before matches changed: lists filtering on them filter again. */
    fun borrowedChanged() {
        for (l in listOf(search, newTitles, holds)) l.borrowedChanged()
    }

    fun placeHold(entry: ListEntry, pickup: String?) = scope.launch {
        try {
            client.placeHold(entry.bib.id, entry.bib.materialType, pickup)
            message = "Hold placed on “${entry.bib.title}”."
            holds.reload()
            search.markHeld(entry.bib.id)
            newTitles.markHeld(entry.bib.id)
        } catch (e: Core.Failure) {
            message = e.message
        }
    }

    fun cancel(hold: Hold) = scope.launch {
        try {
            val refused = client.cancelHolds(listOf(hold))
            message = refused.firstOrNull()?.reason ?: "Hold canceled."
            if (refused.isEmpty()) {
                holds.reload()
                search.reloadIfLoaded()
                newTitles.reloadIfLoaded()
            }
        } catch (e: Core.Failure) {
            message = e.message
        }
    }
}

/** The sort menu's client-side entries; the server's own are its sort ids. */
const val SORT_PEOPLE_WAITING = "~people"
const val SORT_TITLE = "~title"

/**
 * A paged list (search, new titles, holds, checkouts or borrowing history).
 *
 * Paging, sorting and filtering are libbiblio's item list ([Core.CoreList]), shared with the other
 * apps: it says which pages to fetch and which rows to show, and this class fetches those pages and
 * keeps their entries. Once the first page reports the total, every item not fetched yet is a
 * placeholder row, so the scroll bar has its final length; a page is fetched when its placeholders
 * stay on screen briefly. Client sorts and local filters fetch the remaining pages in the background.
 * Use it from the main thread.
 */
class ItemList(val session: Session, val section: Section, private val defaultSort: String? = null) {
    /** A displayed row: a fetched item, or a stand-in for the item at a server position. */
    sealed interface Row {
        val key: String

        data class Item(val entry: ListEntry) : Row {
            override val key get() = entry.id
        }

        data class Placeholder(val position: Int) : Row {
            override val key get() = "placeholder-$position"
        }
    }

    private val list = Core.CoreList(
        when (section) {
            Section.Holds -> Core.CoreList.Kind.Holds
            Section.Checkouts -> Core.CoreList.Kind.Checkouts
            Section.History -> Core.CoreList.Kind.History
            else -> Core.CoreList.Kind.Search
        },
    )

    /** Fetched entries by id; the core list knows their positions. */
    private val entriesById = HashMap<String, ListEntry>()
    private var positions = HashMap<String, Int>()
    private var backgroundJob: Job? = null
    private var dwellJob: Job? = null

    var rows by mutableStateOf<List<Row>>(emptyList())
        private set
    var total by mutableStateOf(0)
        private set
    var loaded by mutableStateOf(false)
        private set
    var loading by mutableStateOf(false)
        private set

    /** Refetching while the stale rows stay in place, until the first page replaces them. */
    var refreshing by mutableStateOf(false)
        private set
    var background by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var query by mutableStateOf("")
        private set

    /** The server sort ids the library offers, from the first page. */
    var serverSorts by mutableStateOf<List<String>>(emptyList())
        private set

    /** The sort chosen: a server id, [SORT_PEOPLE_WAITING] or [SORT_TITLE]; null until chosen. */
    var sort by mutableStateOf<String?>(null)
        private set
    var appliedSort by mutableStateOf<String?>(null)
        private set

    /** The server's FORMAT facet, for catalog lists. */
    var facets by mutableStateOf<List<FacetValue>>(emptyList())
        private set

    /** The loaded items' formats, for account lists. */
    var localFormats by mutableStateOf<List<FacetValue>>(emptyList())
        private set

    /** The format filter: a facet for catalog lists, applied locally for account lists. */
    var format by mutableStateOf<String?>(null)
        private set
    var holdFilter by mutableStateOf(Core.CoreList.HoldFilter.None)
        private set
    var holdCounts by mutableStateOf(IntArray(Core.CoreList.HoldFilter.entries.size))
        private set

    /** "Not Borrowed": hides works this account borrowed in the item's format. */
    var notBorrowed by mutableStateOf(false)
        private set

    private val isCatalog get() = section == Section.Search || section == Section.NewTitles

    /** This list's entry with `id`, if it has been fetched. */
    fun entry(id: String): ListEntry? = entriesById[id]

    private val now get() = SystemClock.elapsedRealtime()

    /** Copies the list's state, rows and formats after a call that may have changed them. */
    private fun sync() {
        val state = list.state()
        total = state.total
        loaded = state.loaded
        loading = state.loading
        refreshing = state.refreshing
        val newRows = ArrayList<Row>()
        val newPositions = HashMap<String, Int>()
        for (row in list.rows()) {
            val id = row.id
            if (id == null) {
                newRows += Row.Placeholder(row.position)
            } else {
                val entry = entriesById[id] ?: continue
                newRows += Row.Item(entry)
                newPositions[id] = row.position
            }
        }
        positions = newPositions
        if (newRows != rows) rows = newRows
        if (!isCatalog) localFormats = list.formats()
        if (section == Section.Holds) holdCounts = IntArray(holdCounts.size) { list.holdCount(Core.CoreList.HoldFilter.entries[it]) }
    }

    // Loading

    /** Loads a list that hasn't been fetched yet, or refetches one older than 15 minutes. */
    fun loadIfNeeded() {
        val state = list.state()
        if (state.loading) return
        if (!state.loaded) reload(keepContent = false) else if (list.isStale(now)) reload(keepContent = true)
    }

    fun reloadIfLoaded() {
        if (list.state().loaded) reload(keepContent = true)
    }

    /** Starts again from the first page; keeping content leaves the rows, stale, until it arrives. */
    fun reload(keepContent: Boolean = true) {
        backgroundJob?.cancel()
        backgroundJob = null
        background = false
        dwellJob?.cancel()
        error = null
        if (section == Section.Search && query.isBlank()) {
            list.clear()
            entriesById.clear()
            facets = emptyList()
            sync()
            return
        }
        val generation = list.reload(keepContent)
        if (!keepContent) entriesById.clear()
        sync()
        session.scope.launch { fetchNow(1, generation) }
    }

    /** A new search: the default sort, no format filter. */
    fun search(text: String) {
        query = text
        sort = null
        appliedSort = null
        format = null
        list.setSort(Core.CoreList.Sort.Server)
        list.setFormat(null)
        reload(keepContent = false)
    }

    /**
     * Pull to refresh. Account lists start a fresh session first: the gateway can keep serving
     * one session a wrong list (checkouts reported empty), and a new session may not.
     */
    fun refresh() {
        if (isCatalog) return reload(keepContent = true)
        list.beginRefresh()
        sync()
        session.scope.launch {
            try {
                session.client.login(force = true)
                session.refreshPatron()
            } catch (e: Core.Failure) {
                // The reload below reports whatever is still wrong.
            }
            reload(keepContent = true)
            // Bring what was borrowed before up to date too.
            session.borrowed?.sync()
        }
    }

    private suspend fun fetch(page: Int): ListPage {
        val server = sort?.takeUnless { it.startsWith("~") } ?: defaultSort
        val client = session.client
        return when (section) {
            Section.Search -> client.search(query, page = page, sort = server, format = format)
            Section.NewTitles -> client.search(
                "nw:[0 TO 180]", searchType = "bl", filters = mapOf("f_on_order" to "false"),
                page = page, sort = server, format = format,
            )
            Section.Holds -> client.holds(page, server)
            Section.Checkouts -> client.checkouts(page, server)
            else -> client.history(page, server)
        }
    }

    /** Fetches a page the core list requested (it is in flight there); false if that failed. */
    private suspend fun fetchNow(page: Int, generation: Long): Boolean = try {
        apply(fetch(page), page, generation)
        true
    } catch (e: Core.Failure) {
        if (list.fail(generation, page)) {
            error = e.message
            sync()
        }
        false
    }

    private fun apply(result: ListPage, page: Int, generation: Long) {
        if (generation != list.generation) return
        // The first page of a refresh replaces the stale entries.
        if (page == 1 && list.state().refreshing) entriesById.clear()
        // An item that moved between pages while fetching keeps its first position.
        for (e in result.entries) entriesById.putIfAbsent(e.id, e)
        list.apply(generation, result, now)
        if (page == 1 || result.facets.isNotEmpty()) facets = result.facets.firstOrNull { it.id == "FORMAT" }?.values.orEmpty()
        if (result.sortOptions.isNotEmpty()) serverSorts = result.sortOptions
        if (sort == null) appliedSort = result.appliedSort
        sync()
        if (page == 1 && list.wantsAllPages()) startBackground()
    }

    // Scrolling

    /** A placeholder scrolled into view: its page is fetched if it is still visible shortly after. */
    fun placeholderAppeared(position: Int) {
        if (refreshing) return
        list.placeholderAppeared(position)
        dwellJob?.cancel()
        dwellJob = session.scope.launch {
            delay(PLACEHOLDER_DWELL_MS)
            val generation = list.generation
            for (page in list.takeVisibleRequests()) launch { fetchNow(page, generation) }
        }
    }

    fun placeholderDisappeared(position: Int) {
        if (!refreshing) list.placeholderDisappeared(position)
    }

    /** An item scrolled into view: prefetch the next page when nearing its placeholders. */
    fun itemAppeared(entry: ListEntry) {
        if (refreshing) return
        val position = positions[entry.id] ?: return
        val page = list.itemAppeared(position)
        if (page > 0) {
            val generation = list.generation
            session.scope.launch { fetchNow(page, generation) }
        }
    }

    /**
     * Fetches the remaining pages, one at a time, for client sorts, local filters, and holds
     * (whose filter counts need every hold).
     */
    private fun startBackground() {
        if (!list.beginBackground()) return
        val generation = list.generation
        background = true
        backgroundJob = session.scope.launch {
            try {
                while (generation == list.generation) {
                    val page = list.nextBackgroundPage()
                    if (page <= 0) break
                    if (!fetchNow(page, generation)) {
                        list.endBackground()
                        break
                    }
                }
            } finally {
                if (generation == list.generation) {
                    background = false
                    backgroundJob = null
                }
            }
        }
    }

    // Filtering and sorting

    fun setSort(id: String) {
        sort = id
        when (id) {
            SORT_PEOPLE_WAITING, SORT_TITLE -> {
                list.setSort(if (id == SORT_TITLE) Core.CoreList.Sort.Title else Core.CoreList.Sort.PeopleWaiting)
                sync()
                startBackground()
            }
            else -> {
                list.setSort(Core.CoreList.Sort.Server)
                reload(keepContent = true)
            }
        }
    }

    fun setFormat(value: String?) {
        format = value
        // Searches filter on the server, except for refined formats, which the core list filters.
        list.setFormat(value)
        if (isCatalog) return reload(keepContent = true)
        sync()
        if (list.needsAllPages()) startBackground()
    }

    fun setHoldFilter(filter: Core.CoreList.HoldFilter) {
        holdFilter = filter
        list.setHoldFilter(filter)
        sync()
        if (list.needsAllPages()) startBackground()
    }

    fun setNotBorrowed(on: Boolean) {
        notBorrowed = on
        applyNotBorrowed()
    }

    /** The account's borrowed-before index changed: filter on it again. */
    fun borrowedChanged() {
        if (notBorrowed) applyNotBorrowed()
    }

    private fun applyNotBorrowed() {
        list.setNotBorrowed(if (notBorrowed) listOfNotNull(session.borrowed?.index) else emptyList())
        sync()
        if (list.needsAllPages()) startBackground()
    }

    /** Shows a just-placed hold on catalog rows without reloading. */
    fun markHeld(metadataId: String) {
        var changed = false
        for ((id, e) in entriesById.entries.toList()) if (e.bib.id == metadataId && e.kind == "catalog") {
            entriesById[id] = e.copy(accountStatus = AccountStatus("onHold"))
            changed = true
        }
        if (changed) sync()
    }

    fun close() {
        backgroundJob?.cancel()
        dwellJob?.cancel()
        list.close()
    }

    private companion object {
        /** How long placeholders must stay visible before their page is fetched, so dragging the scroll bar across a long list doesn't request every page it passes. */
        const val PLACEHOLDER_DWELL_MS = 300L
    }
}
