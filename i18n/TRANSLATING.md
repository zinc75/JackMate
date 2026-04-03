# Contributing a Translation to JackMate

Thank you for helping translate JackMate!

## What you need to do

1. Copy `Localizable_template.strings` and rename it `Localizable_XX.strings`
   (where `XX` is the language code, e.g. `es`, `pt`, `ja`, `nl`…)
2. Translate the values on the right side of each `=`
3. Submit your file as a pull request, or send it by email

That's it. You don't need to touch any Xcode project file.

## File format

```
"key" = "translated value";
```

- Only translate the **right side** (after `=`)
- Keep the **key** (left side) unchanged
- Lines starting with `/*` are comments — ignore them

### Plural forms

Some keys have `[one]` / `[other]` suffixes — translate both:

```
"toolbar.tidy.selected %lld [one]"  = "Tidy — sort 1 selected node";
"toolbar.tidy.selected %lld [other]" = "Tidy — sort %lld selected nodes";
```

### Format specifiers

Keep `%@`, `%lld`, `%1$@`, `%2$lld` etc. exactly as-is — they are replaced at runtime with actual values.

## Terms to keep in English

The following are standard audio/technical terms used internationally — do **not** translate them:

`Jack`, `MIDI`, `CV`, `BBT`, `BPM`, `sample rate`, `buffer`, `xrun`,
`Hog mode`, `Clock drift correction`, `Patchbay`, `Homebrew`, `Tidy`,
`Timebase Master`, `Fan-out`, `Wrap`, `CLI`

## Keys to leave unchanged

A few keys at the bottom of the template are marked `/* UNTRANSLATED */` —
these are technical literals (e.g. `JackMate`, `·`, `CLI`) that are used
as-is in all languages. Leave them as comments; do not add translations.

## Questions?

Open an issue or start a discussion on GitHub.
