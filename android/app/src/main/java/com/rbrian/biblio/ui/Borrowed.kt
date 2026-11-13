package com.rbrian.biblio.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.R
import com.rbrian.biblio.core.Bib
import com.rbrian.biblio.core.Borrowed
import com.rbrian.biblio.core.Core
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * What one signed-in account borrowed before: libbiblio's index ([Core.BorrowedIndex]), synced in
 * the background through the core's shared throttle and kept in a private file that isn't backed
 * up. Nothing is kept while the library's borrowing history is off. Use it from the main thread.
 */
class BorrowedHistory(private val session: Session) {
    /** Entries indexed, the history's size as the library last reported it, and the index's generation. */
    data class State(
        val fetched: Int = 0,
        val total: Int = 0,
        /** Every page fetched once: matches are complete, and "Not Borrowed" is offered. */
        val complete: Boolean = false,
        val syncing: Boolean = false,
        val generation: Long = 0,
    )

    val index = Core.BorrowedIndex()
    private var loaded = false
    private var closed = false
    private var syncJob: Job? = null
    private var fileJob: Job? = null
    private var pendingFileOp: (() -> Unit)? = null

    var state by mutableStateOf(State())
        private set

    private val subdomain get() = session.library.subdomain
    private val username get() = session.username

    // Syncing

    /** After signing in: forgets everything when the library keeps no history, else loads the saved index and brings it up to date. */
    fun start(historyEnabled: Boolean?) {
        if (historyEnabled == false) clear() else sync()
    }

    /** Fetches what's new (or, the first time, every page, resuming where it stopped). */
    fun sync() {
        if (closed) return
        if (session.patron?.borrowingHistoryEnabled == false) return clear()
        loadIfNeeded()
        run(index.beginSync())
    }

    /** Refresh Borrowing History: forgets the index and fetches it all again. */
    fun rebuild() {
        if (closed) return
        loadIfNeeded()
        val page = index.rebuild()
        save()
        // 0: a sync already running carries on from page 1.
        run(page)
    }

    /** Borrowing history turned off: nothing stays on the device. */
    fun clear() {
        if (closed) return
        syncJob?.cancel()
        syncJob = null
        index.clear()
        loaded = true
        file { session.store.deleteBorrowed(subdomain, username) }
        refresh()
    }

    private fun run(first: Int) {
        if (first <= 0) return refresh()
        syncJob = session.scope.launch {
            var page = first
            while (page > 0) {
                page = try {
                    val fetched = page
                    session.client.historyPage(fetched).use { index.apply(fetched, it) }.also { save() }
                } catch (e: Exception) {
                    Core.messageOf(e, "")
                    index.fail()
                    0
                }
                refresh()
            }
        }
        refresh()
    }

    private fun refresh() {
        if (closed) return
        val p = index.progress()
        val new = State(p.fetched, p.total, p.complete, p.syncing, index.generation)
        val changed = new.generation != state.generation
        state = new
        if (changed) session.borrowedChanged()
    }

    // Matching

    /** Whether the patron borrowed this item, or the same work in another format. */
    fun match(bib: Bib): Borrowed? {
        // Reading the state recomposes callers when the matches change.
        if (closed || state.fetched == 0) return null
        return index.lookup(bib)
    }

    // Storage

    private fun loadIfNeeded() {
        if (loaded) return
        loaded = true
        session.store.loadBorrowed(subdomain, username)?.let { index.importBytes(it) }
        refresh()
    }

    private fun save() {
        val bytes = index.exportBytes() ?: return
        file { session.store.saveBorrowed(subdomain, username, bytes) }
    }

    /** Runs the latest file write or delete off the main thread, one at a time; a newer one supersedes a waiting one. */
    private fun file(op: () -> Unit) {
        pendingFileOp = op
        if (fileJob?.isActive == true) return
        fileJob = session.scope.launch {
            while (true) {
                val next = pendingFileOp ?: break
                pendingFileOp = null
                withContext(Dispatchers.IO) { next() }
            }
        }
    }

    /** After the session's lists are closed, since they may still refer to the index. */
    fun close() {
        closed = true
        syncJob?.cancel()
        index.close()
    }
}

/** How "borrowed before" reads. */
object BorrowedText {
    private fun formatted(date: String?, pattern: String): String? = date?.let {
        runCatching { LocalDate.parse(it.take(10)).format(DateTimeFormatter.ofPattern(pattern)) }.getOrNull()
    }

    /** "the audiobook", "on Blu-ray", "the book", or "as Kit". */
    fun borrowedFormat(code: String, session: Session): String {
        val name = session.formatName(code)
        return when (code) {
            "AB", "BOOK_CD", "PLAYAWAY_AUDIOBOOK" -> session.str(R.string.borrowed_the_audiobook)
            "DVD", "BLURAY", "UK", "DVD_PBLURAY", "VIDEO_ONLINE" -> session.str(R.string.borrowed_on, name)
            "BK", "LPRINT", "EBOOK" -> session.str(R.string.borrowed_the, name.lowercase())
            else -> session.str(R.string.borrowed_as, name)
        }
    }

    /** For a row's mark: "Borrowed before · returned Mar 2024", or "Borrowed the audiobook · Mar 2024". */
    fun short(m: Borrowed, session: Session): String {
        val whenText = formatted(m.lastReturned ?: m.lastCheckout, "LLL yyyy")
        if (m.sameFormat) {
            val verb = session.str(if (m.lastReturned != null) R.string.borrowed_returned_when else R.string.borrowed_borrowed_when, whenText ?: "")
            return listOfNotNull(session.str(R.string.borrowed_before), whenText?.let { verb }).joinToString(" · ")
        }
        return listOfNotNull(session.str(R.string.borrowed_what, borrowedFormat(m.format, session)), whenText).joinToString(" · ")
    }

    /** For item detail: "You borrowed this in March 2024 · 3 times", or "You borrowed on DVD in March 2024". */
    fun sentence(m: Borrowed, session: Session): String {
        val what = if (m.sameFormat) session.str(R.string.borrowed_this) else borrowedFormat(m.format, session)
        var text = session.str(R.string.you_borrowed, what)
        formatted(m.lastCheckout ?: m.lastReturned, "LLLL yyyy")?.let { text += session.str(R.string.borrowed_in, it) }
        if (m.count > 1) text += " · " + session.plural(R.plurals.times_borrowed, m.count)
        return text
    }
}

/** A row's quiet "borrowed before" mark, fainter for the same work in another format. */
@Composable
fun BorrowedMark(match: Borrowed, session: Session) {
    Icon(
        Icons.Filled.History,
        contentDescription = BorrowedText.short(match, session),
        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (match.sameFormat) 1f else 0.5f),
        modifier = Modifier.size(14.dp),
    )
}

/** Item detail's "You borrowed this…" line. */
@Composable
fun BorrowedLine(match: Borrowed, session: Session) {
    val text = BorrowedText.sentence(match, session)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.clearAndSetSemantics { contentDescription = text },
    ) {
        Icon(
            Icons.Filled.History, contentDescription = null, modifier = Modifier.size(18.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (match.sameFormat) 1f else 0.5f),
        )
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** "Refresh Borrowing History", and "Updating · 340 of 1,200" with a small progress bar while the history syncs. */
@Composable
fun BorrowedRefresh(borrowed: BorrowedHistory, enabled: Boolean) {
    val state = borrowed.state
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { borrowed.rebuild() }, enabled = enabled && !state.syncing) { Text(stringResource(R.string.refresh_borrowing_history)) }
        if (state.syncing) {
            val numbers = NumberFormat.getIntegerInstance()
            if (state.total > 0) {
                LinearProgressIndicator(
                    progress = { minOf(state.fetched, state.total).toFloat() / state.total },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(stringResource(R.string.updating_progress, numbers.format(state.fetched), numbers.format(state.total)),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(stringResource(R.string.updating), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
