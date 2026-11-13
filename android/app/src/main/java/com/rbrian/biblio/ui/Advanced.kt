package com.rbrian.biblio.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.R
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.Facet
import com.rbrian.biblio.core.prettified

/** A search term's field, as the "bl" query language names it, and the label for it. */
private val FIELDS = listOf(
    "anywhere" to R.string.field_keyword,
    "title" to R.string.field_title,
    "contributor" to R.string.field_author,
    "subject" to R.string.field_subject,
    "series" to R.string.field_series,
    "genre" to R.string.field_genre,
    "publisher" to R.string.field_publisher,
    "isbn" to R.string.field_isbn,
    "callnumber" to R.string.field_call_number,
)

private val OPERATORS = listOf("AND" to R.string.op_and, "OR" to R.string.op_or, "NOT" to R.string.op_not)

private val AUDIENCES = listOf("adult" to "Adult", "teen" to "Teen", "juvenile" to "Children")

private val LANGUAGES = listOf("eng", "spa", "chi", "fre", "ger", "jpn", "kor", "rus", "vie", "ara", "hin", "por", "tgl", "ita")

private class Term(field: String, var op: String = "AND") {
    var field by mutableStateOf(field)
    var text by mutableStateOf("")
    var operator by mutableStateOf(op)
}

/** A label from the library's own localized strings, else [fallback]. */
private fun Session.label(key: String, fallback: String): String = library.labels[key] ?: fallback

/** Builds a field-qualified query such as `title:(dune) AND contributor:(herbert)`, with limits for format, audience, language, and years. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedSearchSheet(session: Session, onDismiss: () -> Unit, onSearch: (String, Map<String, String>, String?) -> Unit) {
    val terms = remember { mutableStateListOf(Term("anywhere"), Term("title"), Term("contributor")) }
    var format by remember { mutableStateOf<String?>(null) }
    var audience by remember { mutableStateOf<String?>(null) }
    var language by remember { mutableStateOf<String?>(null) }
    var fromYear by remember { mutableStateOf("") }
    var toYear by remember { mutableStateOf("") }

    val query = run {
        val parts = ArrayList<String>()
        for (t in terms) {
            val text = t.text.trim()
            if (text.isEmpty()) continue
            val clause = "${t.field}:($text)"
            parts += if (parts.isEmpty()) (if (t.operator == "NOT") "NOT $clause" else clause) else "${t.operator} $clause"
        }
        val from = fromYear.trim().toIntOrNull()
        val to = toYear.trim().toIntOrNull()
        if ((from != null || to != null) && parts.isNotEmpty()) parts += "AND pubyear:[${from ?: "*"} TO ${to ?: "*"}]"
        parts.joinToString(" ")
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(stringResource(R.string.advanced_search), style = MaterialTheme.typography.titleLarge)
            Text(stringResource(R.string.search_for), style = MaterialTheme.typography.titleMedium)
            terms.forEachIndexed { i, term ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (i > 0) Menu(OPERATORS.first { it.first == term.operator }.second.let { stringResource(it) }, Modifier.weight(1f)) { close ->
                            for ((op, label) in OPERATORS) DropdownMenuItem(text = { Text(stringResource(label)) }, onClick = { term.operator = op; close() })
                        }
                        Menu(stringResource(FIELDS.first { it.first == term.field }.second), Modifier.weight(2f)) { close ->
                            for ((field, label) in FIELDS) DropdownMenuItem(text = { Text(stringResource(label)) }, onClick = { term.field = field; close() })
                        }
                    }
                    OutlinedTextField(
                        value = term.text, onValueChange = { term.text = it }, singleLine = true,
                        label = { Text(stringResource(R.string.terms)) }, modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            TextButton(onClick = { terms += Term("anywhere") }) { Text(stringResource(R.string.add_term)) }

            Text(stringResource(R.string.limit_to), style = MaterialTheme.typography.titleMedium)
            val formats = remember { Core.formatCodes.sortedBy { session.formatName(it) } }
            Menu(stringResource(R.string.format_value, format?.let { session.formatName(it) } ?: stringResource(R.string.any)), Modifier.fillMaxWidth()) { close ->
                DropdownMenuItem(text = { Text(stringResource(R.string.any)) }, onClick = { format = null; close() })
                for (code in formats) DropdownMenuItem(text = { Text(session.formatName(code)) }, onClick = { format = code; close() })
            }
            Menu(stringResource(R.string.audience_value, AUDIENCES.firstOrNull { it.first == audience }?.let { session.label("AUDIENCE.${it.first}", it.second) } ?: stringResource(R.string.any)), Modifier.fillMaxWidth()) { close ->
                DropdownMenuItem(text = { Text(stringResource(R.string.any)) }, onClick = { audience = null; close() })
                for ((code, name) in AUDIENCES) DropdownMenuItem(text = { Text(session.label("AUDIENCE.$code", name)) }, onClick = { audience = code; close() })
            }
            Menu(stringResource(R.string.language_value, language?.let { session.label("LANGUAGE.$it", it) } ?: stringResource(R.string.any)), Modifier.fillMaxWidth()) { close ->
                DropdownMenuItem(text = { Text(stringResource(R.string.any)) }, onClick = { language = null; close() })
                for (code in LANGUAGES) DropdownMenuItem(text = { Text(session.label("LANGUAGE.$code", code)) }, onClick = { language = code; close() })
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = fromYear, onValueChange = { fromYear = it.filter(Char::isDigit).take(4) }, singleLine = true,
                    label = { Text(stringResource(R.string.published_from)) }, modifier = Modifier.weight(1f),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                OutlinedTextField(
                    value = toYear, onValueChange = { toYear = it.filter(Char::isDigit).take(4) }, singleLine = true,
                    label = { Text(stringResource(R.string.published_to)) }, modifier = Modifier.weight(1f),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
            }
            Text(query.ifEmpty { stringResource(R.string.enter_a_term) }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(
                onClick = {
                    val filters = buildMap {
                        audience?.let { put("f_AUDIENCE", it) }
                        language?.let { put("f_LANGUAGE", it) }
                    }
                    onSearch(query, filters, format)
                },
                enabled = query.isNotEmpty(), modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.search)) }
        }
    }
}

/** A drop-down button showing [label]; [items] gets a function that closes the menu. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Menu(label: String, modifier: Modifier, items: @Composable (close: () -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }, modifier = modifier) {
        OutlinedTextField(
            value = label, onValueChange = {}, readOnly = true, singleLine = true,
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
            modifier = Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) { items { open = false } }
    }
}

/** "Filter by": each of the search's facets besides format, with its values and counts. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun FilterBySheet(session: Session, list: ItemList, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.filter_by), style = MaterialTheme.typography.titleLarge)
            for (facet in list.otherFacets) {
                val name = "f_${facet.id}"
                Text(facetTitle(session, facet), style = MaterialTheme.typography.titleMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (v in facet.values) FilterChip(
                        selected = list.filters[name] == v.value,
                        onClick = { list.selectFilter(name, if (list.filters[name] == v.value) null else v.value) },
                        label = { Text(session.label("${facet.id}.${v.value}", v.value.prettified()) + if (v.count >= 0) " (${v.count})" else "") },
                    )
                }
            }
        }
    }
}

private fun facetTitle(session: Session, facet: Facet): String = session.label("FACET.${facet.id}", facet.id.prettified())
