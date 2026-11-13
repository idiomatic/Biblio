package com.rbrian.biblio.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.automirrored.filled.Help
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.ShoppingBag
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.rbrian.biblio.R
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.CopyAvailability
import com.rbrian.biblio.core.DetailField
import com.rbrian.biblio.core.ListEntry

/** Jacket, title, holds, borrowed before, availability by location (color-coded, always worded) and the full record. */
@Composable
fun ItemDetail(session: Session, entry: ListEntry, needSignIn: () -> Unit) {
    val bib = entry.bib
    val details = remember(session, entry) { itemDetails(session, bib) }
    var copies by remember(bib.id) { mutableStateOf<List<CopyAvailability>?>(null) }
    var fields by remember(bib.id) { mutableStateOf<List<DetailField>>(emptyList()) }
    var copiesError by remember(bib.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(bib.id) {
        try {
            copies = session.client.availability(bib.id)
        } catch (e: Exception) {
            copiesError = Core.messageOf(e, session.str(R.string.load_failed))
        }
        fields = try {
            session.client.details(bib.id).items
        } catch (e: Exception) {
            Core.messageOf(e, "")
            emptyList()
        }
    }

    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            AsyncImage(
                model = bib.jacketLarge ?: bib.jacketSmall, contentDescription = null, contentScale = ContentScale.Fit,
                modifier = Modifier.size(width = 110.dp, height = 165.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(bib.title, style = MaterialTheme.typography.headlineSmall)
                bib.subtitle?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                bib.authors.firstOrNull()?.let { author ->
                    Text(author, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(vertical = 2.dp))
                }
                Text(details, color = MaterialTheme.colorScheme.onSurfaceVariant)
                AvailabilityLine(bib)
                AccountCapsule(entry)
            }
        }
        HoldActions(session, entry, needSignIn)
        session.borrowed?.match(bib)?.let { BorrowedLine(it, session) }
        bib.summary?.let { Text(it, style = MaterialTheme.typography.bodyLarge) }

        Text(stringResource(R.string.availability_by_location), style = MaterialTheme.typography.titleMedium)
        when {
            copiesError != null -> Text(copiesError!!, color = MaterialTheme.colorScheme.error)
            copies == null -> Text(stringResource(R.string.loading), color = MaterialTheme.colorScheme.onSurfaceVariant)
            copies!!.isEmpty() -> Text(stringResource(R.string.no_copies), color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> Column { copies!!.forEach { CopyRow(it) } }
        }

        if (fields.isNotEmpty()) {
            Text(stringResource(R.string.details), style = MaterialTheme.typography.titleMedium)
            Column {
                fields.forEach { f ->
                    ListItem(overlineContent = { Text(f.label) }, headlineContent = { Text(f.values.joinToString("\n")) })
                }
            }
        }
    }
}

@Composable
private fun CopyRow(copy: CopyAvailability) {
    val color = StatusColors.copy(copy.kind)
    ListItem(
        leadingContent = { Icon(copy.kind.icon, contentDescription = null, tint = color) },
        headlineContent = { Text(copy.branch) },
        supportingContent = {
            val detail = listOfNotNull(copy.collection, copy.callNumber, copy.dueDate?.let { stringResource(R.string.due_on, shortDate(it) ?: it) }).joinToString(" · ")
            if (detail.isNotEmpty()) Text(detail)
        },
        trailingContent = { Text(copy.status, color = color, modifier = Modifier.width(120.dp)) },
    )
    HorizontalDivider()
}

private val String.icon: ImageVector
    get() = when (this) {
        "available" -> Icons.Filled.CheckCircle
        "onOrder" -> Icons.Filled.Inventory2
        "out" -> Icons.Filled.Schedule
        "held" -> Icons.Filled.ShoppingBag
        "transit" -> Icons.AutoMirrored.Filled.CompareArrows
        "repair" -> Icons.Filled.Build
        "missing", "claimsReturned" -> Icons.AutoMirrored.Filled.Help
        else -> Icons.Filled.Circle
    }

/** Place a hold at a chosen pickup location, or cancel this account's hold. */
@Composable
private fun HoldActions(session: Session, entry: ListEntry, needSignIn: () -> Unit) {
    val hold = entry.hold
    when {
        hold != null -> if (hold.canCancel) {
            OutlinedButton(
                onClick = { session.cancel(hold) },
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) { Text(stringResource(R.string.cancel_hold)) }
        }
        entry.checkout != null || entry.history != null -> {}
        // Guests choose a card first: the sign-in sheet, then the hold.
        session.isGuest -> if (entry.bib.holdable) Button(onClick = needSignIn) { Text(stringResource(R.string.place_hold)) }
        entry.accountStatus != null -> {}
        entry.bib.holdable -> {
            var pickup by remember(entry.id, session.patron?.preferredPickup) { mutableStateOf(session.patron?.preferredPickup) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                PickupField(session, pickup, Modifier.weight(1f)) { pickup = it }
                Button(onClick = { session.placeHold(entry, pickup) }) { Text(stringResource(R.string.place_hold)) }
            }
        }
    }
}

/** The pickup location menu; nothing until the account's locations arrive. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PickupField(session: Session, pickup: String?, modifier: Modifier = Modifier, onPick: (String) -> Unit) {
    if (session.locations.isEmpty()) return
    var open by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }, modifier = modifier) {
        OutlinedTextField(
            value = session.locations.firstOrNull { it.id == pickup }?.name ?: stringResource(R.string.pickup_location),
            onValueChange = {}, readOnly = true, label = { Text(stringResource(R.string.pick_up_at)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
            modifier = Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            session.locations.forEach { loc ->
                DropdownMenuItem(text = { Text(loc.name) }, onClick = { onPick(loc.id); open = false })
            }
        }
    }
}
