package com.rbrian.biblio.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.rbrian.biblio.core.Core
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
            } catch (e: Core.Failure) {
                signInError = e.message
            }
        }
    }

    fun close() {
        scope.coroutineContext[Job]?.cancel()
        client.close()
    }

    fun refreshPatron() {
        patron = runCatching { client.patron() }.getOrNull() ?: patron
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
            message = refused.firstOrNull()?.reason ?: "Hold cancelled."
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

/**
 * A paged list (search, new titles, holds, checkouts or history). Pages load as the list
 * scrolls near its end; sorting and the format filter reload from the first page.
 */
class ItemList(val session: Session, val section: Section, private val defaultSort: String? = null) {
    val entries = mutableStateListOf<ListEntry>()
    var page by mutableStateOf<ListPage?>(null)
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var query by mutableStateOf("")
    var sort by mutableStateOf<String?>(null)
    var format by mutableStateOf<String?>(null)
    private var job: Job? = null

    val loaded get() = page != null
    val hasMore get() = page?.let { it.page < it.pages } ?: false

    fun loadIfNeeded() {
        if (!loaded && !loading) reload()
    }

    fun reloadIfLoaded() {
        if (loaded) reload()
    }

    fun reload() {
        job?.cancel()
        entries.clear()
        page = null
        error = null
        loading = false
        if (section == Section.Search && query.isBlank()) return
        load(1)
    }

    fun loadMore() {
        val p = page ?: return
        if (!loading && p.page < p.pages) load(p.page + 1)
    }

    private fun load(number: Int) {
        loading = true
        job = session.scope.launch {
            try {
                val client = session.client
                val order = sort ?: defaultSort
                val result = when (section) {
                    Section.Search -> client.search(query, page = number, sort = order, format = format)
                    Section.NewTitles -> client.search(
                        "nw:[0 TO 180]", searchType = "bl", filters = mapOf("f_on_order" to "false"),
                        page = number, sort = order, format = format,
                    )
                    Section.Holds -> client.holds(number, order)
                    Section.Checkouts -> client.checkouts(number, order)
                    else -> client.history(number, order)
                }
                entries += result.entries
                page = result
            } catch (e: Core.Failure) {
                error = e.message
            } finally {
                loading = false
            }
        }
    }

    /** Shows a just-placed hold on catalog rows without reloading. */
    fun markHeld(metadataId: String) {
        for (i in entries.indices) if (entries[i].bib.id == metadataId) {
            entries[i] = entries[i].copy(accountStatus = com.rbrian.biblio.core.AccountStatus("onHold"))
        }
    }
}
