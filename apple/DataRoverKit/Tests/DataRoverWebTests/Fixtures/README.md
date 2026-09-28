# Test fixtures

Trimmed captures of real Wikipedia pages, used by `WikipediaFixtureTests` to
check `PageSimplifier` and `ReaderExtractor` against a real page structure.

| File | Source | Captured |
| --- | --- | --- |
| `wikipedia-Main_Page.html` | https://en.wikipedia.org/wiki/Main_Page | 2026-09-28 |
| `wikipedia-United_States.html` | https://en.wikipedia.org/wiki/United_States | 2026-09-28 |

Trimming: every `<script>`, `<style>`, `<link>` and HTML comment was removed
from both pages. `wikipedia-United_States.html` also lost its "References" and "External links" sections, and its `srcset`,
`decoding`, `typeof`, `about`, `data-mw*` and `data-file-*` attributes, to
keep the file small. Every other article section is kept, so reader-view
scoring sees the same balance of sections as the live page. The rest of the DOM
is as served, including the `<body>` with several top-level children and the
article nested inside `div.mw-page-container`.

Licence: Wikipedia text is available under the Creative Commons
Attribution-ShareAlike 4.0 License (https://creativecommons.org/licenses/by-sa/4.0/).
The text is by Wikipedia contributors; see each page's history at the source
URL for attribution. These trimmed copies are distributed under the same
licence.
