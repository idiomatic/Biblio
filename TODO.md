# TODO

- **Localization.** Make the app's text, and the core's messages, localizable with a String
  Catalog, following the platform's language settings, independent of the library account's
  language. Format dates (due, pickup) with the system locale.
- **Title sort.** Sort titles as people expect: ignoring case and accents, with numbers by
  value ("Book 2" before "Book 10", "Émile" before "Zoolander"). The core's title sort handles
  numbers and case, but not accents.
- **Selected content bleeds into sidebar and detail.** On iPadOS, selecting an item has a
  detrimental visual effect on the adjacent views. Is this a Biblio bug or bad design from
  Apple?
- **Lock-screen barcode.** Show the barcode on the lock screen when in the library.
