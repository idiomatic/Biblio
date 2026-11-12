package com.rbrian.biblio.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwitchAccount
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffold
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.ListEntry
import kotlinx.coroutines.launch

private val Section.icon: ImageVector
    get() = when (this) {
        Section.Search -> Icons.Filled.Search
        Section.NewTitles -> Icons.Filled.AutoAwesome
        Section.Holds -> Icons.Filled.Bookmarks
        Section.Checkouts -> Icons.AutoMirrored.Filled.LibraryBooks
        Section.History -> Icons.Filled.History
        Section.Account -> Icons.Filled.AccountCircle
    }

/**
 * One account: a navigation bar on phones (a rail on tablets and foldables) for the
 * sections, and a list–detail layout that shows both panes when there is room.
 */
@Composable
fun SessionScreen(session: Session, onSwitch: () -> Unit) {
    DisposableEffect(session) { onDispose { session.close() } }
    var section by rememberSaveable { mutableStateOf(Section.Search) }
    val sections = if (session.isGuest) listOf(Section.Search, Section.NewTitles) else Section.entries
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(session.message) {
        session.message?.let { snackbar.showSnackbar(it); session.message = null }
    }
    LaunchedEffect(session.signInError) { session.signInError?.let { snackbar.showSnackbar(it) } }

    NavigationSuiteScaffold(
        navigationSuiteItems = {
            for (s in sections) item(
                selected = section == s,
                onClick = { section = s; session.list(s)?.loadIfNeeded() },
                icon = {
                    val count = when (s) {
                        Section.Holds -> session.holds.total.takeIf { session.holds.loaded }
                        Section.Checkouts -> session.checkouts.total.takeIf { session.checkouts.loaded }
                        else -> null
                    }
                    if (count != null && count > 0) BadgedBox(badge = { Badge { Text("$count") } }) { Icon(s.icon, null) }
                    else Icon(s.icon, null)
                },
                label = { Text(s.title, maxLines = 1) },
            )
        },
    ) {
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
            Box(Modifier.padding(padding)) {
                when (section) {
                    Section.Account -> AccountScreen(session, onSwitch)
                    else -> ListDetail(session, session.list(section)!!, onSwitch)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun ListDetail(session: Session, list: ItemList, onSwitch: () -> Unit) {
    // The navigator saves its destination, so it holds the entry's id rather than the entry.
    val navigator = rememberListDetailPaneScaffoldNavigator<String>()
    BackHandler(navigator.canNavigateBack()) { navigator.navigateBack() }
    ListDetailPaneScaffold(
        directive = navigator.scaffoldDirective,
        value = navigator.scaffoldValue,
        listPane = {
            AnimatedPane {
                ItemListPane(session, list, onSwitch) { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, it.id) }
            }
        },
        detailPane = {
            AnimatedPane {
                navigator.currentDestination?.content?.let { id -> list.entry(id) }?.let { ItemDetail(session, it) }
                    ?: Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("Select an item", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ItemListPane(session: Session, list: ItemList, onSwitch: () -> Unit, onSelect: (ListEntry) -> Unit) {
    val state = rememberLazyListState()
    LaunchedEffect(list) { list.loadIfNeeded() }
    Column {
        if (list.section == Section.Search) {
            var text by rememberSaveable { mutableStateOf(list.query) }
            SearchBar(
                inputField = {
                    SearchBarDefaults.InputField(
                        query = text,
                        onQueryChange = { text = it },
                        onSearch = { list.search(it) },
                        expanded = false,
                        onExpandedChange = {},
                        placeholder = { Text("Search ${session.library.displayName}") },
                        leadingIcon = { Icon(Icons.Filled.Search, null) },
                        trailingIcon = { IconButton(onClick = onSwitch) { Icon(Icons.Filled.SwitchAccount, "Switch user or library") } },
                    )
                },
                expanded = false,
                onExpandedChange = {},
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            ) {}
        } else {
            TopAppBar(
                title = { Text(list.section.title) },
                actions = { IconButton(onClick = onSwitch) { Icon(Icons.Filled.SwitchAccount, "Switch user or library") } },
            )
        }
        Controls(session, list)
        PullToRefreshBox(isRefreshing = list.refreshing, onRefresh = { list.refresh() }, modifier = Modifier.fillMaxSize()) {
            when {
                list.rows.isEmpty() && (list.loading || list.refreshing) -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                list.rows.isEmpty() -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text(
                        list.error ?: when (list.section) {
                            Section.Search -> if (list.query.isBlank()) "Find books, movies, music, and more." else "No results."
                            Section.Holds -> "Items you place on hold appear here."
                            Section.Checkouts -> "Nothing checked out."
                            Section.History -> "If borrowing history is on in Account, items you return appear here."
                            else -> "No new titles."
                        },
                        color = if (list.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                else -> LazyColumn(state = state, modifier = Modifier.fillMaxSize().alpha(if (list.refreshing) 0.5f else 1f)) {
                    items(list.rows, key = { it.key }) { row ->
                        when (row) {
                            is ItemList.Row.Item -> {
                                // Nearing the placeholders after this item: prefetch their page.
                                LaunchedEffect(row.entry.id) { list.itemAppeared(row.entry) }
                                EntryRow(session, row.entry) { onSelect(row.entry) }
                            }
                            is ItemList.Row.Placeholder -> {
                                // Its page is fetched once the placeholder has stayed on screen briefly.
                                DisposableEffect(row.position) {
                                    list.placeholderAppeared(row.position)
                                    onDispose { list.placeholderDisappeared(row.position) }
                                }
                                PlaceholderRow()
                            }
                        }
                    }
                    if (list.error != null) item {
                        Text(list.error ?: "", color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp))
                    }
                }
            }
        }
    }
}

/** Sort menu, hold status filters for holds, format chips, and "Not Borrowed". */
@Composable
private fun Controls(session: Session, list: ItemList) {
    if (list.rows.isEmpty() && !list.loaded) return
    val isCatalog = list.section == Section.Search || list.section == Section.NewTitles
    // "Not Borrowed" is offered once the whole history is indexed, so it never hides less than it says.
    val offerNotBorrowed = (isCatalog || list.section == Section.Holds) &&
        (session.borrowed?.state?.complete == true || list.notBorrowed)
    Column {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            var open by remember { mutableStateOf(false) }
            val sorts = list.serverSorts + SORT_PEOPLE_WAITING + (if ("title" in list.serverSorts) emptyList() else listOf(SORT_TITLE))
            if (list.serverSorts.isNotEmpty()) Box {
                IconButton(onClick = { open = true }) { Icon(Icons.AutoMirrored.Filled.Sort, "Sort") }
                DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                    for (id in sorts) DropdownMenuItem(
                        text = {
                            Text(
                                when (id) {
                                    SORT_PEOPLE_WAITING -> "People waiting"
                                    SORT_TITLE -> "Title"
                                    else -> session.library.sortName(id)
                                },
                            )
                        },
                        trailingIcon = { if (id == (list.sort ?: list.appliedSort)) Icon(Icons.Filled.Check, null) },
                        onClick = { open = false; list.setSort(id) },
                    )
                }
            }
            val formats = if (isCatalog) list.facets else list.localFormats
            val notBorrowedHere = offerNotBorrowed && isCatalog
            if (formats.isNotEmpty() || list.format != null || notBorrowedHere) LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (notBorrowedHere) item(key = "notBorrowed") { NotBorrowedChip(list) }
                items(formats, key = { it.value }) { f ->
                    FilterChip(
                        selected = list.format == f.value,
                        onClick = { list.setFormat(if (list.format == f.value) null else f.value) },
                        // A refined format's count is unknown (-1) until the core has filtered every page.
                        label = { Text(session.library.formatName(f.value) + if (f.count >= 0) " (${f.count})" else "") },
                    )
                }
            }
        }
        if (list.section == Section.Holds) LazyRow(
            Modifier.padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val filters = listOf(
                Core.CoreList.HoldFilter.Ready to "Ready",
                Core.CoreList.HoldFilter.NotReady to "Not ready",
                Core.CoreList.HoldFilter.OnOrder to "On order",
            )
            items(filters, key = { it.first.name }) { (filter, name) ->
                FilterChip(
                    selected = list.holdFilter == filter,
                    onClick = { list.setHoldFilter(if (list.holdFilter == filter) Core.CoreList.HoldFilter.None else filter) },
                    label = { Text("$name (${list.holdCounts[filter.ordinal]})") },
                )
            }
            if (offerNotBorrowed) item(key = "notBorrowed") { NotBorrowedChip(list) }
        }
    }
}

/** The "Not Borrowed" filter: shows only what this account hasn't borrowed in that format. */
@Composable
private fun NotBorrowedChip(list: ItemList) {
    FilterChip(
        selected = list.notBorrowed,
        onClick = { list.setNotBorrowed(!list.notBorrowed) },
        label = { Text("Not Borrowed") },
        leadingIcon = {
            Icon(if (list.notBorrowed) Icons.Filled.Check else Icons.Filled.History, null, Modifier.size(FilterChipDefaults.IconSize))
        },
    )
}

/** Stands in for an item that hasn't been fetched yet. */
@Composable
private fun PlaceholderRow() {
    ListItem(
        modifier = Modifier.height(96.dp),
        leadingContent = { Box(Modifier.size(width = 48.dp, height = 72.dp)) },
        headlineContent = { Text("") },
    )
}

@Composable
private fun EntryRow(session: Session, entry: ListEntry, onClick: () -> Unit) {
    val bib = entry.bib
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        leadingContent = {
            AsyncImage(
                model = bib.jacketSmall, contentDescription = null, contentScale = ContentScale.Fit,
                modifier = Modifier.size(width = 48.dp, height = 72.dp),
            )
        },
        headlineContent = { Text(bib.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column {
                bib.authors.firstOrNull()?.let { Text(it, maxLines = 1) }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(listOfNotNull(session.library.formatName(bib.format), bib.year).joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    // Catalog and hold rows only: checkouts and history are borrowed by definition.
                    if (entry.kind == "catalog" || entry.kind == "hold") session.borrowed?.match(bib)?.let { BorrowedMark(it, session.library) }
                }
                StatusLine(entry)
            }
        },
    )
}

@Composable
fun StatusLine(entry: ListEntry) {
    val status = entry.accountStatus
    val (text, color) = when {
        status?.kind == "checkedOut" -> (status.due?.let { "Checked out · due $it" } ?: "Checked out") to StatusColors.copy("held")
        status != null && status.ready -> "Ready for pickup" to StatusColors.copy("available")
        status != null -> (status.position?.let { "On hold · #$it" } ?: "On hold") to StatusColors.copy("transit")
        entry.history != null -> (entry.history.returnedDate?.let { "Returned $it" } ?: "") to MaterialTheme.colorScheme.onSurfaceVariant
        else -> {
            val b = entry.bib
            val label = when (b.status) { "AVAILABLE" -> "Available"; "ON_ORDER" -> "On order"; "UNAVAILABLE", "NOT_AVAILABLE" -> "All copies in use"; else -> null }
            val counts = if (b.totalCopies > 0) "${b.heldCopies} holds on ${b.totalCopies} copies" else null
            listOfNotNull(label, counts).joinToString(" · ") to StatusColors.availability(b.status)
        }
    }
    if (text.isNotEmpty()) Text(text, style = MaterialTheme.typography.bodySmall, color = color)
}
