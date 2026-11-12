# TODO

- **Localization.** Make the app's text, and the core's messages, localizable with a String
  Catalog, following the platform's language settings, independent of the library account's
  language. Format dates (due, pickup) with the system locale.
- **Selected content bleeds into sidebar and detail.** On iPadOS, selecting an item has a
  detrimental visual effect on the adjacent views. Is this a Biblio bug or bad design from
  Apple?
- **Squashed rows on a list's first visit (macOS).** Opening Borrowing History soon after
  launch briefly shows its rows squashed, as if drawn before their heights are measured. A
  minimum row height (`defaultMinListRowHeight`) may fix it, but it would also apply to the
  lists' header rows (search field, filter bars); reproduce it in a macOS guest first.
- **Lock-screen barcode.** A Lock Screen control now opens the barcode. Showing it
  automatically when in the library needs a Wallet pass (Code128, not Codabar) or similar.
- **Disclose the throttling report.** Tell users, in the README and the About box or a privacy
  note, that Biblio keeps a local log of 429 and 5xx responses (time, status, method, host, masked
  path, retry delay, requests in flight), that nothing is sent unless they copy and share the
  report, and what the risks are: the log persists on the device until the app is deleted, and a
  copied report names the library host and the times of the user's activity.
- **Check the status bar on an iPod Touch.** The bottom status bar (`TITLE [SIZE KiB]`) is checked on the iPhone 13 mini, iPhone 17, iPad mini, iPad (A16), and Mac. No iPod Touch simulator exists, so look at it on a device. On iPhone the item sheet covers the bar while it loads locations.
