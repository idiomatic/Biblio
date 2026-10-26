# BiblioCommons gateway notes

Discovered from the patron web app (`wccls.bibliocommons.com`) and its JS bundle.

Base: `https://gateway.bibliocommons.com/v2/libraries/{subdomain}`

Auth headers on every authenticated call: `X-Session-Id`, `X-Access-Token`, `Accept: application/json`.

| Purpose | Method / path | Notes |
|---|---|---|
| Log in | `POST /sessions` `{username,password}` | → `auth.sessionId`, `auth.authToken`, `auth.currentUserId`, `entities.users[uid].accounts[0]`, `entities.users[uid].preferences.language`, `userContact.email` |
| Current session | `GET /sessions/current` | |
| Holds | `GET /holds?accountId&page&sort&locale` | page size fixed at 25; `borrowing.holds.items` = hold ids, `entities.holds`, `entities.bibs` |
| Place hold | `POST /holds` `{metadataId,materialType,accountId,enableSingleClickHolds,materialParams:{branchId,errorMessageLocale}}` | |
| Cancel hold | `DELETE /holds` `{accountId,holdIds,metadataIds}` | |
| Checkouts | `GET /checkouts?accountId&page&sort&locale` | |
| Borrowing history | `GET /borrowinghistory?accountId&page&locale` | |
| Borrowing history setting | `PUT /accounts/{accountId}/settings/borrowingHistorySetting` `{enabled}` | current value: `entities.accounts[id].borrowingHistoryEnabled` in the login response |
| Search | `POST /bibs/search` `{query,searchType,page,sort,f_FORMAT,f_on_order,...}` | `catalogSearch.results[].representative`, `entities.bibs[id].{briefInfo,availability,policy}`; `availability.heldCopies` = people waiting |
| New titles | search with `query:"nw:[0 TO 180]", searchType:"bl", sort:"newly_acquired", f_on_order:"true"/"false"` | "Filter by" = `f_FORMAT`, `f_FICTION_TYPE`, `f_AUDIENCE`, `f_LANGUAGE` |
| Availability by location | `GET /bibs/{id}/availability` (public) | `entities.bibItems[*].{branchName,collection,callNumber,dueDate,availability.libraryStatus}` |
| Detail | `GET /catalogbibs/{id}` (public) | `entities.catalogBibs[id].fields[].items[].fieldValues[].primary.values` |
| Locations | `GET /locations?limit=100` (public) | |

Labels: page state JSON (`<script type="application/json">`) → `localization.messages` (`FORMAT.bluray`, `sort.*`), `branding.primaryBrandColor`.

Account settings are Rails forms on `https://{subdomain}.bibliocommons.com` (the gateway login's cookies authenticate them). GET the page, POST its form with the hidden `authenticity_token`:

| Setting | Page | Form action | Fields |
|---|---|---|---|
| Email | `/account/email` | `/account/contact_information` | `user_email`, `user_digital_email` |
| Password | `/account/password` | `/account/change_pin` | `old_password`, `new_password`, `new_password_confirm` (4–64 alphanumeric) |
| Pickup location | `/account/pickup_location` | `/account/preferred_branches` | `first_preference`, `second_preference`, `third_preference`, `sch_toggle` |
| Language | `/account/language` | `/account/user_lang` | `user_lang` (e.g. `en-US`) |
