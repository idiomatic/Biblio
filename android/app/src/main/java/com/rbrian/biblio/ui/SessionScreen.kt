package com.rbrian.biblio.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.BookmarkRemove
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
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
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.rbrian.biblio.R
import com.rbrian.biblio.core.Bib
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.ListEntry
import com.rbrian.biblio.data.LibraryStore

private val Section.icon: ImageVector
    get() = when (this) {
        Section.Search -> Icons.Filled.Search
        Section.NewTitles -> Icons.Filled.AutoAwesome
        Section.Holds -> Icons.Filled.Bookmarks
        Section.Checkouts -> Icons.AutoMirrored.Filled.LibraryBooks
        Section.History -> Icons.Filled.History
        Section.Account -> Icons.Filled.AccountCircle
    }

/** What the top bars' overflow menu does: switch user or library, sign in (guests), and About. */
class Chrome(val isGuest: Boolean, val onSwitch: () -> Unit, val onSignIn: () -> Unit, val onAbout: () -> Unit)

/** The overflow menu every top bar ends with. */
@Composable
fun OverflowMenu(chrome: Chrome) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Filled.MoreVert, stringResource(R.string.more)) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (chrome.isGuest) DropdownMenuItem(text = { Text(stringResource(R.string.sign_in)) }, onClick = { open = false; chrome.onSignIn() })
            DropdownMenuItem(text = { Text(stringResource(R.string.switch_user_or_library)) }, onClick = { open = false; chrome.onSwitch() })
            DropdownMenuItem(text = { Text(stringResource(R.string.about_biblio)) }, onClick = { open = false; chrome.onAbout() })
        }
    }
}

/**
 * One account: a navigation bar on phones (a rail on tablets and foldables) for the
 * sections, and a list–detail layout that shows both panes when there is room.
 */
@Composable
fun SessionScreen(session: Session, store: LibraryStore, onSwitch: () -> Unit, onSignIn: (String) -> Unit) {
    var section by rememberSaveable { mutableStateOf(Section.Search) }
    var about by rememberSaveable { mutableStateOf(false) }
    var signingIn by rememberSaveable { mutableStateOf(false) }
    val sections = if (session.isGuest) listOf(Section.Search, Section.NewTitles) else Section.entries
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(session.message) {
        session.message?.let { snackbar.showSnackbar(it); session.message = null }
    }
    LaunchedEffect(session.signInError) { session.signInError?.let { snackbar.showSnackbar(it) } }
    val chrome = remember(session, onSwitch) {
        Chrome(session.isGuest, onSwitch, onSignIn = { signingIn = true }, onAbout = { about = true })
    }
    val needSignIn = { signingIn = true }

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
                    if (count != null && count > 0) {
                        val description = pluralStringResource(
                            if (s == Section.Holds) R.plurals.badge_holds else R.plurals.badge_checkouts, count, count,
                        )
                        BadgedBox(
                            badge = { Badge { Text("$count") } },
                            modifier = Modifier.clearAndSetSemantics { contentDescription = description },
                        ) { Icon(s.icon, null) }
                    } else Icon(s.icon, null)
                },
                label = { Text(stringResource(s.title), maxLines = 1) },
            )
        },
    ) {
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
            Box(Modifier.padding(padding)) {
                when (section) {
                    Section.Account -> AccountScreen(session, store, chrome)
                    // Keyed by section, so each section's list–detail starts without the last one's open item.
                    else -> key(section) { ListDetail(session, session.list(section)!!, chrome, needSignIn) }
                }
            }
        }
    }

    if (about) AboutDialog(onDismiss = { about = false })
    if (signingIn && session.isGuest) GuestSignInSheet(
        store, session.library, onDismiss = { signingIn = false },
        onSignedIn = { signingIn = false; onSignIn(it) },
    )
    if (session.passwordLost) ReenterPasswordDialog(session, onSwitch)
}

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun ListDetail(session: Session, list: ItemList, chrome: Chrome, needSignIn: () -> Unit) {
    // The navigator saves its destination, so it holds the entry's id rather than the entry.
    val navigator = rememberListDetailPaneScaffoldNavigator<String>()
    BackHandler(navigator.canNavigateBack()) { navigator.navigateBack() }
    ListDetailPaneScaffold(
        directive = navigator.scaffoldDirective,
        value = navigator.scaffoldValue,
        listPane = {
            AnimatedPane {
                ItemListPane(session, list, chrome, needSignIn) { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, it.id) }
            }
        },
        detailPane = {
            AnimatedPane {
                navigator.currentDestination?.content?.let { id -> list.entry(id) }?.let { ItemDetail(session, it, needSignIn) }
                    ?: Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(stringResource(R.string.select_an_item), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ItemListPane(session: Session, list: ItemList, chrome: Chrome, needSignIn: () -> Unit, onSelect: (ListEntry) -> Unit) {
    val state = rememberLazyListState()
    LaunchedEffect(list) { list.loadIfNeeded() }
    val selecting = list.selection.isNotEmpty()
    BackHandler(selecting) { list.clearSelection() }
    var advanced by remember { mutableStateOf(false) }
    var filterBy by remember { mutableStateOf(false) }
    var confirmHolds by remember { mutableStateOf(false) }
    var confirmCancel by remember { mutableStateOf(false) }
    // Only catalog lists place holds and only the holds list cancels them; the others don't select.
    val canSelect = list.section == Section.Search || list.section == Section.NewTitles || list.section == Section.Holds
    Column {
        if (selecting) {
            TopAppBar(
                title = { Text(pluralStringResource(R.plurals.selected, list.selection.size, list.selection.size)) },
                navigationIcon = { IconButton(onClick = { list.clearSelection() }) { Icon(Icons.Filled.Close, stringResource(R.string.clear_selection)) } },
                actions = {
                    if (list.section == Section.Holds) {
                        IconButton(onClick = { confirmCancel = true }) { Icon(Icons.Filled.BookmarkRemove, stringResource(R.string.cancel_holds)) }
                    } else {
                        IconButton(onClick = { if (session.isGuest) needSignIn() else confirmHolds = true }) {
                            Icon(Icons.Filled.BookmarkAdd, stringResource(R.string.place_holds))
                        }
                    }
                },
            )
        } else if (list.section == Section.Search) {
            var text by rememberSaveable { mutableStateOf(list.query) }
            // An advanced search or a guest's sign-in sets the query from elsewhere.
            LaunchedEffect(list.query) { text = list.query }
            SearchBar(
                inputField = {
                    SearchBarDefaults.InputField(
                        query = text,
                        onQueryChange = { text = it },
                        onSearch = { list.search(it) },
                        expanded = false,
                        onExpandedChange = {},
                        placeholder = { Text(stringResource(R.string.search_library, session.library.displayName)) },
                        leadingIcon = { Icon(Icons.Filled.Search, null) },
                        trailingIcon = {
                            Row {
                                IconButton(onClick = { advanced = true }) { Icon(Icons.Filled.Tune, stringResource(R.string.advanced_search)) }
                                OverflowMenu(chrome)
                            }
                        },
                    )
                },
                expanded = false,
                onExpandedChange = {},
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            ) {}
        } else {
            TopAppBar(
                title = { Text(stringResource(list.section.title)) },
                actions = { OverflowMenu(chrome) },
            )
        }
        Controls(session, list, onFilterBy = { filterBy = true })
        PullToRefreshBox(isRefreshing = list.refreshing, onRefresh = { list.refresh() }, modifier = Modifier.fillMaxSize()) {
            when {
                list.rows.isEmpty() && (list.loading || list.refreshing) -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                list.rows.isEmpty() -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text(
                        list.error ?: stringResource(
                            when (list.section) {
                                Section.Search -> if (list.query.isBlank()) R.string.empty_search_prompt else R.string.empty_search_none
                                Section.Holds -> R.string.empty_holds
                                Section.Checkouts -> R.string.empty_checkouts
                                Section.History -> R.string.empty_history
                                else -> R.string.empty_new_titles
                            },
                        ),
                        color = if (list.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                else -> LazyColumn(state = state, modifier = Modifier.fillMaxSize().alpha(if (list.refreshing) 0.5f else 1f)) {
                    items(list.rows, key = { it.key }) { row ->
                        when (row) {
                            is ItemList.Row.Item -> {
                                // Nearing the placeholders after this item: prefetch their page.
                                LaunchedEffect(row.entry.id) { list.itemAppeared(row.entry) }
                                EntryRow(
                                    session, row.entry,
                                    selected = row.entry.id in list.selection,
                                    onClick = { if (selecting) list.toggleSelected(row.entry.id) else onSelect(row.entry) },
                                    onLongClick = if (canSelect) ({ list.toggleSelected(row.entry.id) }) else null,
                                )
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

    if (advanced) AdvancedSearchSheet(
        session, onDismiss = { advanced = false },
        onSearch = { query, filters, format -> advanced = false; list.advancedSearch(query, filters, format) },
    )
    if (filterBy) FilterBySheet(session, list, onDismiss = { filterBy = false })
    if (confirmHolds) {
        val entries = list.selectedEntries().filter { it.kind == "catalog" && it.bib.holdable && it.accountStatus == null }
        PlaceHoldsDialog(
            session, entries, skipped = list.selection.size - entries.size,
            onDismiss = { confirmHolds = false },
            onPlace = { pickup -> confirmHolds = false; list.clearSelection(); session.placeHolds(entries, pickup) },
        )
    }
    if (confirmCancel) {
        val holds = list.selectedEntries().mapNotNull { it.hold }.filter { it.canCancel }
        AlertDialog(
            onDismissRequest = { confirmCancel = false },
            title = { Text(pluralStringResource(R.plurals.cancel_holds_title, holds.size, holds.size)) },
            text = { Text(stringResource(R.string.cancel_holds_text)) },
            confirmButton = {
                TextButton(
                    onClick = { confirmCancel = false; list.clearSelection(); session.cancelHolds(holds) },
                    enabled = holds.isNotEmpty(),
                ) { Text(stringResource(R.string.cancel_holds), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmCancel = false }) { Text(stringResource(R.string.keep_holds)) } },
        )
    }
}

/** Asks where to pick up the selected items, then places a hold on each. */
@Composable
private fun PlaceHoldsDialog(session: Session, entries: List<ListEntry>, skipped: Int, onDismiss: () -> Unit, onPlace: (String?) -> Unit) {
    var pickup by remember(session.patron?.preferredPickup) { mutableStateOf(session.patron?.preferredPickup) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(pluralStringResource(R.plurals.place_holds_title, entries.size, entries.size)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (skipped > 0) Text(
                    pluralStringResource(R.plurals.place_holds_skipped, skipped, skipped),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                PickupField(session, pickup) { pickup = it }
            }
        },
        confirmButton = { TextButton(onClick = { onPlace(pickup) }, enabled = entries.isNotEmpty()) { Text(stringResource(R.string.place_holds)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Sort menu, hold status filters for holds, New Titles' filters, format chips, and "Not Borrowed". */
@Composable
private fun Controls(session: Session, list: ItemList, onFilterBy: () -> Unit) {
    if (list.rows.isEmpty() && !list.loaded && list.section != Section.NewTitles) return
    val isCatalog = list.section == Section.Search || list.section == Section.NewTitles
    // "Not Borrowed" is offered once the whole history is indexed, so it never hides less than it says.
    val offerNotBorrowed = (isCatalog || list.section == Section.Holds) &&
        (session.borrowed?.state?.complete == true || list.notBorrowed)
    Column {
        if (list.section == Section.NewTitles) LazyRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item(key = "arrived") {
                FilterChip(
                    selected = list.onOrder == false,
                    onClick = { list.selectOnOrder(false) },
                    label = { Text(stringResource(R.string.just_arrived)) },
                )
            }
            item(key = "onOrder") {
                FilterChip(
                    selected = list.onOrder == true,
                    onClick = { list.selectOnOrder(true) },
                    label = { Text(stringResource(R.string.on_order)) },
                )
            }
        }
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            var open by remember { mutableStateOf(false) }
            val sorts = list.serverSorts + SORT_PEOPLE_WAITING + (if ("title" in list.serverSorts) emptyList() else listOf(SORT_TITLE))
            if (list.serverSorts.isNotEmpty()) Box {
                IconButton(onClick = { open = true }) { Icon(Icons.AutoMirrored.Filled.Sort, stringResource(R.string.sort)) }
                DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                    for (id in sorts) DropdownMenuItem(
                        text = {
                            Text(
                                when (id) {
                                    SORT_PEOPLE_WAITING -> stringResource(R.string.sort_people_waiting)
                                    SORT_TITLE -> stringResource(R.string.sort_title)
                                    else -> session.library.sortName(id)
                                },
                            )
                        },
                        trailingIcon = { if (id == (list.sort ?: list.appliedSort)) Icon(Icons.Filled.Check, null) },
                        onClick = { open = false; list.selectSort(id) },
                    )
                }
            }
            val formats = if (isCatalog) list.facets else list.localFormats
            val notBorrowedHere = offerNotBorrowed && isCatalog
            if (formats.isNotEmpty() || list.format != null || notBorrowedHere || (isCatalog && list.otherFacets.isNotEmpty())) LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (isCatalog && list.otherFacets.isNotEmpty()) item(key = "filterBy") {
                    FilterChip(
                        selected = list.filters.isNotEmpty(),
                        onClick = onFilterBy,
                        label = { Text(stringResource(R.string.filter_by)) },
                        leadingIcon = { Icon(Icons.Filled.Tune, null, Modifier.size(FilterChipDefaults.IconSize)) },
                    )
                }
                if (notBorrowedHere) item(key = "notBorrowed") { NotBorrowedChip(list) }
                items(formats, key = { it.value }) { f ->
                    FilterChip(
                        selected = list.format == f.value,
                        onClick = { list.selectFormat(if (list.format == f.value) null else f.value) },
                        // A refined format's count is exact once the core has seen every item; until then it has none (-1).
                        label = { Text(session.formatName(f.value) + if (f.count >= 0) " (${f.count})" else "") },
                    )
                }
            }
        }
        if (list.section == Section.Holds) LazyRow(
            Modifier.padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val filters = listOf(
                Core.CoreList.HoldFilter.Ready to R.string.filter_ready,
                Core.CoreList.HoldFilter.NotReady to R.string.filter_not_ready,
                Core.CoreList.HoldFilter.OnOrder to R.string.filter_on_order,
            )
            items(filters, key = { it.first.name }) { (filter, name) ->
                FilterChip(
                    selected = list.holdFilter == filter,
                    onClick = { list.selectHoldFilter(if (list.holdFilter == filter) Core.CoreList.HoldFilter.None else filter) },
                    label = { Text(stringResource(R.string.filter_with_count, stringResource(name), list.holdCounts[filter.ordinal])) },
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
        onClick = { list.selectNotBorrowed(!list.notBorrowed) },
        label = { Text(stringResource(R.string.not_borrowed)) },
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

/** "Format · Year · Edition", each part once: the edition is dropped when it only repeats the format. */
fun itemDetails(session: Session, bib: Bib): String {
    val format = session.formatName(bib.format)
    val edition = bib.edition?.takeIf { it.isNotBlank() && !it.equals(format, ignoreCase = true) && !it.equals(bib.format, ignoreCase = true) }
    return listOfNotNull(format, bib.year, edition).joinToString(" · ")
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EntryRow(session: Session, entry: ListEntry, selected: Boolean, onClick: () -> Unit, onLongClick: (() -> Unit)?) {
    val bib = entry.bib
    val haptic = LocalHapticFeedback.current
    val details = remember(session, entry) { itemDetails(session, bib) }
    ListItem(
        modifier = Modifier.combinedClickable(
            onClick = onClick,
            onLongClick = onLongClick?.let { long -> { haptic.performHapticFeedback(HapticFeedbackType.LongPress); long() } },
        ),
        colors = ListItemDefaults.colors(containerColor = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.14f) else Color.Transparent),
        leadingContent = {
            Box(contentAlignment = Alignment.BottomEnd) {
                AsyncImage(
                    model = bib.jacketSmall, contentDescription = null, contentScale = ContentScale.Fit,
                    modifier = Modifier.size(width = 48.dp, height = 72.dp),
                )
                if (selected) Icon(
                    Icons.Filled.Check, stringResource(R.string.selected_row),
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(20.dp).background(MaterialTheme.colorScheme.primary, CircleShape).padding(2.dp),
                )
            }
        },
        headlineContent = { Text(bib.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                bib.authors.firstOrNull()?.let { Text(it, maxLines = 1) }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(details, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    // Catalog and hold rows only: checkouts and history are borrowed by definition.
                    if (entry.kind == "catalog" || entry.kind == "hold") session.borrowed?.match(bib)?.let { BorrowedMark(it, session) }
                }
                AvailabilityLine(bib)
                AccountCapsule(entry)
            }
        },
    )
}
