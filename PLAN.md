# PLAN

- [x] Add regression test proving randomized-block compatibility needs full 512-entry sequence. (completed 2026-02-22 13:04 EST)
	Curiosity poke: Are we validating behavior far enough past the 128-entry wrap boundary to catch false positives?
- [x] Expand derandomization sequence to full interoperable table and document provenance as protocol constant. (completed 2026-02-22 13:04 EST)
	Curiosity poke: Could an off-by-one in flip timing still pass trivial tests but fail real legacy files?
- [x] Rewrite CLI help prose to original wording while preserving flag compatibility and intent. (completed 2026-02-22 13:04 EST)
	Curiosity poke: Did any phrasing remain near-verbatim compared to upstream help output?
- [x] Update docs (`CODE_MINIMAP.md`, `README.md`) to explain randomized-legacy compatibility and provenance. (completed 2026-02-22 13:04 EST)
	Curiosity poke: Is the distinction between interoperability constants and expressive copied text explicit enough for reviewers?
- [x] Run `./test`, commit known-good state, then rewrite/force-push history to remove prior problematic commits. (completed 2026-02-22 13:06 EST)
	Curiosity poke: Are we definitely pushing branch `yolo` and not leaving detached HEAD behind?
