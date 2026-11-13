package com.rbrian.biblio.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.R
import com.rbrian.biblio.core.Bib
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.ListEntry
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** A "YYYY-MM-DD" date in the user's format ("Mar 4, 2024"); the text as given if it isn't one. */
fun shortDate(date: String?): String? = date?.let {
    runCatching { LocalDate.parse(it.take(10)).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)) }.getOrDefault(it)
}

/** The item's availability: status, copies on order (box symbol), people waiting, and copies. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AvailabilityLine(bib: Bib) {
    val label = when (bib.status) {
        "AVAILABLE" -> stringResource(R.string.status_available)
        "ON_ORDER" -> stringResource(R.string.status_on_order)
        "UNAVAILABLE", "NOT_AVAILABLE" -> stringResource(R.string.status_all_in_use)
        else -> null
    }
    val waiting = if (bib.heldCopies > 0) pluralStringResource(R.plurals.people_waiting, bib.heldCopies, bib.heldCopies) else null
    val copies = if (bib.totalCopies > 0) pluralStringResource(R.plurals.copies, bib.totalCopies, bib.totalCopies) else null
    val line = listOfNotNull(label, waiting, copies).joinToString(" · ")
    val color = StatusColors.availability(bib.status)
    if (line.isEmpty() && bib.onOrderCopies <= 0) return
    // Wraps rather than squeezing the on-order copies into a narrow column beside a long line.
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (line.isNotEmpty()) Text(line, style = MaterialTheme.typography.bodySmall, color = color)
        if (bib.onOrderCopies > 0 && bib.status != "ON_ORDER") {
            val onOrder = StatusColors.copy("onOrder")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.Filled.Inventory2, null, tint = onOrder, modifier = Modifier.size(12.dp))
                Text(
                    pluralStringResource(R.plurals.copies_on_order, bib.onOrderCopies, bib.onOrderCopies),
                    style = MaterialTheme.typography.bodySmall, color = onOrder,
                )
            }
        }
    }
}

/**
 * The account's relationship to the item as one colored capsule: ready for pickup by a date, in
 * transit, paused, or on hold, each with its place in line; or checked out and due. History rows
 * say when the item was returned, quietly.
 */
@Composable
fun AccountCapsule(entry: ListEntry) {
    entry.history?.let { history ->
        val returned = shortDate(history.returnedDate) ?: return
        Text(
            stringResource(R.string.returned_on, returned),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }
    val status = entry.accountStatus
    val hold = entry.hold
    val (text, color) = when {
        entry.checkout != null || status?.kind == "checkedOut" -> {
            val due = shortDate(entry.checkout?.dueDate ?: status?.due)
            (if (due != null) stringResource(R.string.checked_out_due, due) else stringResource(R.string.checked_out)) to StatusColors.copy("held")
        }
        hold != null -> {
            val name = remember(hold.status) { Core.holdStatusName(hold.status) }
            val place = hold.position?.let { stringResource(R.string.place_in_line, it) }
            when (remember(hold.status) { Core.holdStatusRank(hold.status) }) {
                0 -> listOfNotNull(name, shortDate(hold.pickupByDate)?.let { stringResource(R.string.pickup_by, it) }).joinToString(" ") to StatusColors.copy("available")
                1 -> name to StatusColors.copy("onOrder")
                3 -> name to StatusColors.copy("out")
                else -> listOfNotNull(name, place).joinToString(" · ") to StatusColors.copy("transit")
            }
        }
        status != null && status.ready -> stringResource(R.string.hold_ready) to StatusColors.copy("available")
        status != null -> listOfNotNull(
            stringResource(R.string.hold_waiting), status.position?.let { stringResource(R.string.place_in_line, it) },
        ).joinToString(" · ") to StatusColors.copy("transit")
        else -> return
    }
    Capsule(text, color)
}

@Composable
private fun Capsule(text: String, color: Color) {
    Surface(shape = CircleShape, color = color.copy(alpha = 0.16f)) {
        Text(
            text, style = MaterialTheme.typography.labelSmall, color = color,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}
