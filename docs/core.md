# libbiblio results

These are the shapes of what operations return in `result`. Requests and the list of
operations are in [core/include/biblio.h](../core/include/biblio.h). Keys are camelCase. Null
optional fields are left out.

```text
Bib            { id, title, subtitle?, authors[], format, publicationDate?, edition?, callNumber?,
                 summary?, jacketSmall?, jacketLarge?, materialType, holdable, status?,
                 heldCopies, availableCopies, totalCopies, onOrderCopies }
ListEntry      { id, bib: Bib, kind: "catalog"|"hold"|"checkout"|"history", serverIndex,
                 hold?: Hold, checkout?: Checkout, history?: HistoryEntry, accountStatus?: AccountStatus }
AccountStatus  { kind: "onHold"|"checkedOut", ready, position?, due? }
ListPage       { entries[], page, pages, count, pageSize, facets[{ id, values[{ value, count }] }],
                 sortOptions[], appliedSort? }
Hold           { id, metadataId, status, position?, pickupLocation?, expiryDate?, pickupByDate?,
                 suspendEndDate?, canCancel }
Checkout       { id, metadataId, status?, dueDate?, checkoutDate?, timesRenewed? }
HistoryEntry   { id, metadataId, checkoutDate?, returnedDate? }
CopyAvailability { id, branch, status, isAvailable, collection?, callNumber?, dueDate?, isOnOrder,
                 kind: available|onOrder|out|held|transit|repair|missing|withdrawn|claimsReturned|libraryUseOnly|other }
DetailField    { label, values[] }
Location       { id, name }
Patron         { userId, accountId, name, email?, language, barcode?, preferredPickup?,
                 borrowingHistoryEnabled? }
LibraryInfo    { subdomain, name, shortName?, primaryColor?, website?, labels{}, languages[], users[] }
DirectoryEntry { name, website?, region?, logo? }
```

Catalog rows (`kind: "catalog"`) carry `accountStatus` and `hold` when the signed-in account
already has the title, through any of its editions, on hold or checked out.
