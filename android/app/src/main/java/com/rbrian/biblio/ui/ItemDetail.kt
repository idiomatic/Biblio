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
import androidx.compose.material.icons.filled.Help
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
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.rbrian.biblio.core.CopyAvailability
import com.rbrian.biblio.core.DetailField
import com.rbrian.biblio.core.ListEntry
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonPrimitive

/** Jacket, title, holds, availability by location (color-coded, always worded) and the full record. */
@Composable
fun ItemDetail(session: Session, entry: ListEntry) {
    val bib = entry.bib
    var copies by remember(bib.id) { mutableStateOf<List<CopyAvailability>?>(null) }
    var fields by remember(bib.id) { mutableStateOf<List<DetailField>>(emptyList()) }
    var copiesError by remember(bib.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(bib.id) {
        try {
            copies = session.client.call(ListSerializer(CopyAvailability.serializer()), "availability") { put("metadataId", JsonPrimitive(bib.id)) }
        } catch (e: Exception) {
            copiesError = e.message
        }
        fields = runCatching {
            session.client.call(ListSerializer(DetailField.serializer()), "details") { put("metadataId", JsonPrimitive(bib.id)) }
        }.getOrDefault(emptyList())
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
                Text(listOfNotNull(session.library.formatName(bib.format), bib.year).joinToString(" · "),
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                StatusLine(entry)
            }
        }
        HoldActions(session, entry)
        bib.summary?.let { Text(it, style = MaterialTheme.typography.bodyLarge) }

        Text("Availability by location", style = MaterialTheme.typography.titleMedium)
        when {
            copiesError != null -> Text(copiesError!!, color = MaterialTheme.colorScheme.error)
            copies == null -> Text("Loading…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            copies!!.isEmpty() -> Text("No copies listed.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> Column { copies!!.forEach { CopyRow(it) } }
        }

        if (fields.isNotEmpty()) {
            Text("Details", style = MaterialTheme.typography.titleMedium)
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
            val detail = listOfNotNull(copy.collection, copy.callNumber, copy.dueDate?.let { "due $it" }).joinToString(" · ")
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
        "missing", "claimsReturned" -> Icons.Filled.Help
        else -> Icons.Filled.Circle
    }

/** Place a hold at a chosen pickup location, or cancel this account's hold. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HoldActions(session: Session, entry: ListEntry) {
    val hold = entry.hold
    when {
        hold != null -> if (hold.canCancel) {
            OutlinedButton(
                onClick = { session.cancel(hold) },
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) { Text("Cancel hold") }
        }
        entry.checkout != null -> {}
        session.isGuest -> Text("Sign in to place holds.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        entry.bib.holdable -> {
            var pickup by remember { mutableStateOf(session.patron?.preferredPickup) }
            var open by remember { mutableStateOf(false) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (session.locations.isNotEmpty()) ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }, modifier = Modifier.weight(1f)) {
                    OutlinedTextField(
                        value = session.locations.firstOrNull { it.id == pickup }?.name ?: "Pickup location",
                        onValueChange = {}, readOnly = true, label = { Text("Pick up at") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
                        modifier = Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
                    )
                    ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        session.locations.forEach { loc ->
                            DropdownMenuItem(text = { Text(loc.name) }, onClick = { pickup = loc.id; open = false })
                        }
                    }
                }
                Button(onClick = { session.placeHold(entry, pickup) }) { Text("Place hold") }
            }
        }
    }
}
