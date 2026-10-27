# TODO

- **Rework the language picker.** The operating system owns the user's language choice, so
  Account → Language shouldn't be a separate in-app picker. Follow the system's preferred
  languages instead (per-app language on iOS and macOS is in Settings). Send the closest one
  the library supports to the library account's language setting, so catalog labels match the
  rest of the app.
- **Improve i18n.** The app's own text is hard-coded English, and so are some messages from
  the networking layer. Make that text localizable with a String Catalog. Use the system locale
  to format dates such as due and pickup dates.
