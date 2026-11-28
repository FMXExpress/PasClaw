# Web UI screenshots

Every tab of the embedded web UI, redesigned, captured with headless Chromium against a real gateway and fake providers and servers. All names, numbers and conversations are fixture data, not a real session. Files named `*-phone*` are 390×844; the rest are 1280×900 unless named `full-*` (the whole page).

The README's own screenshots, and the script that makes them, are in [docs/screenshots](../docs/screenshots/README.md).

## Chat

The chat page: the welcome on an empty chat, markdown with real tables and a code block with Copy, tool calls stacked with a failed badge, a long thread, and a reply streaming with **Latest** after scrolling up. Each at desktop and phone width, dark and light.

| | |
|---|---|
| ![Chat, 2-markdown-dark.png](chat/2-markdown-dark.png) | ![Chat, 3-tools-light.png](chat/3-tools-light.png) |

All 28: [1-empty-dark](chat/1-empty-dark.png), [1-empty-light](chat/1-empty-light.png), [1-empty-phone-dark](chat/1-empty-phone-dark.png), [1-empty-phone-light](chat/1-empty-phone-light.png), [2-markdown-dark](chat/2-markdown-dark.png), [2-markdown-light](chat/2-markdown-light.png), [2-markdown-phone-dark](chat/2-markdown-phone-dark.png), [2-markdown-phone-light](chat/2-markdown-phone-light.png), [2b-markdown-end-dark](chat/2b-markdown-end-dark.png), [2b-markdown-end-light](chat/2b-markdown-end-light.png), [2b-markdown-end-phone-dark](chat/2b-markdown-end-phone-dark.png), [2b-markdown-end-phone-light](chat/2b-markdown-end-phone-light.png), [3-tools-dark](chat/3-tools-dark.png), [3-tools-light](chat/3-tools-light.png), [3-tools-phone-dark](chat/3-tools-phone-dark.png), [3-tools-phone-light](chat/3-tools-phone-light.png), [3b-tools-toggled-dark](chat/3b-tools-toggled-dark.png), [3b-tools-toggled-light](chat/3b-tools-toggled-light.png), [3b-tools-toggled-phone-dark](chat/3b-tools-toggled-phone-dark.png), [3b-tools-toggled-phone-light](chat/3b-tools-toggled-phone-light.png), [4-long-dark](chat/4-long-dark.png), [4-long-light](chat/4-long-light.png), [4-long-phone-dark](chat/4-long-phone-dark.png), [4-long-phone-light](chat/4-long-phone-light.png), [5-streaming-dark](chat/5-streaming-dark.png), [5-streaming-light](chat/5-streaming-light.png), [5-streaming-phone-dark](chat/5-streaming-phone-dark.png), [5-streaming-phone-light](chat/5-streaming-phone-light.png).

## Stats

Usage: the token strip, caching and savings, tokens by provider and by model with each one's share, the empty state with counters off, and the in-page Reset confirm.

| | |
|---|---|
| ![Stats, stats-dark.png](stats/stats-dark.png) | ![Stats, stats-light.png](stats/stats-light.png) |

All 5: [stats-confirm](stats/stats-confirm.png), [stats-dark](stats/stats-dark.png), [stats-empty](stats/stats-empty.png), [stats-light](stats/stats-light.png), [stats-phone](stats/stats-phone.png).

## MCP

MCP servers: a row per server (ready, connecting, failed with its error, disabled), the counts strip, a server's tools opened, the empty state and the error state.

| | |
|---|---|
| ![MCP, mcp-servers-dark-desktop-collapsed.png](mcp/mcp-servers-dark-desktop-collapsed.png) | ![MCP, mcp-servers-light-desktop.png](mcp/mcp-servers-light-desktop.png) |

All 11: [mcp-empty-dark-desktop](mcp/mcp-empty-dark-desktop.png), [mcp-empty-dark-phone](mcp/mcp-empty-dark-phone.png), [mcp-empty-light-desktop](mcp/mcp-empty-light-desktop.png), [mcp-empty-light-phone](mcp/mcp-empty-light-phone.png), [mcp-error-dark-desktop](mcp/mcp-error-dark-desktop.png), [mcp-servers-dark-desktop-collapsed](mcp/mcp-servers-dark-desktop-collapsed.png), [mcp-servers-dark-desktop](mcp/mcp-servers-dark-desktop.png), [mcp-servers-dark-phone](mcp/mcp-servers-dark-phone.png), [mcp-servers-light-desktop-collapsed](mcp/mcp-servers-light-desktop-collapsed.png), [mcp-servers-light-desktop](mcp/mcp-servers-light-desktop.png), [mcp-servers-light-phone](mcp/mcp-servers-light-phone.png).

## Cron

Scheduled jobs: the schedule with a plain reading ("Weekdays at 09:00"), the skill and arguments, last run, and the empty state.

| | |
|---|---|
| ![Cron, cron-entries-desktop-dark.png](cron/cron-entries-desktop-dark.png) | ![Cron, cron-entries-desktop-light.png](cron/cron-entries-desktop-light.png) |

All 8: [cron-empty-desktop-dark](cron/cron-empty-desktop-dark.png), [cron-empty-desktop-light](cron/cron-empty-desktop-light.png), [cron-empty-phone-dark](cron/cron-empty-phone-dark.png), [cron-empty-phone-light](cron/cron-empty-phone-light.png), [cron-entries-desktop-dark](cron/cron-entries-desktop-dark.png), [cron-entries-desktop-light](cron/cron-entries-desktop-light.png), [cron-entries-phone-dark](cron/cron-entries-phone-dark.png), [cron-entries-phone-light](cron/cron-entries-phone-light.png).

## Files

The file browser: a folder listing, a text file with line numbers, markdown preview, a large file shown in part, a binary file, a file whose name is HTML (drawn as text), an empty folder, and the stacked phone layout.

| | |
|---|---|
| ![Files, desktop-dark-text.png](files/desktop-dark-text.png) | ![Files, desktop-light-markdown.png](files/desktop-light-markdown.png) |

All 21: [desktop-dark-big.log](files/desktop-dark-big.log.png), [desktop-dark-data.bin](files/desktop-dark-data.bin.png), [desktop-dark-empty-folder](files/desktop-dark-empty-folder.png), [desktop-dark-folder](files/desktop-dark-folder.png), [desktop-dark-html-named-file](files/desktop-dark-html-named-file.png), [desktop-dark-large](files/desktop-dark-large.png), [desktop-dark-text](files/desktop-dark-text.png), [desktop-light-big.log](files/desktop-light-big.log.png), [desktop-light-data.bin](files/desktop-light-data.bin.png), [desktop-light-empty-folder](files/desktop-light-empty-folder.png), [desktop-light-folder](files/desktop-light-folder.png), [desktop-light-html-named-file](files/desktop-light-html-named-file.png), [desktop-light-markdown](files/desktop-light-markdown.png), [desktop-light-text](files/desktop-light-text.png), [phone-dark-data.bin](files/phone-dark-data.bin.png), [phone-dark-folder](files/phone-dark-folder.png), [phone-dark-markdown](files/phone-dark-markdown.png), [phone-dark-text](files/phone-dark-text.png), [phone-light-data.bin](files/phone-light-data.bin.png), [phone-light-folder](files/phone-light-folder.png), [phone-light-text](files/phone-light-text.png).

## Relay

Relay: status line, queue strip, worker rows, Add a worker with the masked token and snippets, and the in-browser worker (unavailable, downloading, connected; the last two staged, since a headless browser has no GPU). `full-*` are whole-page captures.

| | |
|---|---|
| ![Relay, relay-dark.png](relay/relay-dark.png) | ![Relay, relay-light.png](relay/relay-light.png) |

All 14: [full-relay-add](relay/full-relay-add.png), [full-relay-dark-full](relay/full-relay-dark-full.png), [full-relay-dark](relay/full-relay-dark.png), [full-relay-light](relay/full-relay-light.png), [full-relay-phone-full](relay/full-relay-phone-full.png), [full-relay-phone](relay/full-relay-phone.png), [relay-browser-worker-connected](relay/relay-browser-worker-connected.png), [relay-browser-worker-loading-dark](relay/relay-browser-worker-loading-dark.png), [relay-browser-worker-loading-light](relay/relay-browser-worker-loading-light.png), [relay-browser-worker](relay/relay-browser-worker.png), [relay-dark](relay/relay-dark.png), [relay-light](relay/relay-light.png), [relay-phone](relay/relay-phone.png), [relay-snippets-hidden](relay/relay-snippets-hidden.png).

## Memory

Memory: the notes browser and reader (Preview/Source, Copy), search with highlighted snippets, facts with kind and scope pills, Remember and Export, the search setup, and empty states.

| | |
|---|---|
| ![Memory, desktop-dark-notes.png](memory/desktop-dark-notes.png) | ![Memory, desktop-light-facts.png](memory/desktop-light-facts.png) |

All 24: [desktop-dark-empty](memory/desktop-dark-empty.png), [desktop-dark-facts](memory/desktop-dark-facts.png), [desktop-dark-notes](memory/desktop-dark-notes.png), [desktop-light-facts](memory/desktop-light-facts.png), [desktop-light-notes](memory/desktop-light-notes.png), [more-content-desktop-dark-list](memory/more-content-desktop-dark-list.png), [more-content-desktop-dark-search](memory/more-content-desktop-dark-search.png), [more-content-desktop-dark-setup](memory/more-content-desktop-dark-setup.png), [more-content-desktop-light-list](memory/more-content-desktop-light-list.png), [more-content-desktop-light-search](memory/more-content-desktop-light-search.png), [more-content-phone-dark-list](memory/more-content-phone-dark-list.png), [more-content-phone-dark-setup](memory/more-content-phone-dark-setup.png), [more-content-phone-light-list](memory/more-content-phone-light-list.png), [more-empty-desktop-dark-facts](memory/more-empty-desktop-dark-facts.png), [more-empty-desktop-dark-notes](memory/more-empty-desktop-dark-notes.png), [more-empty-desktop-light-facts](memory/more-empty-desktop-light-facts.png), [more-empty-desktop-light-notes](memory/more-empty-desktop-light-notes.png), [more-empty-phone-dark-facts](memory/more-empty-phone-dark-facts.png), [more-empty-phone-dark-notes](memory/more-empty-phone-dark-notes.png), [more-empty-phone-light-facts](memory/more-empty-phone-light-facts.png), [more-empty-phone-light-notes](memory/more-empty-phone-light-notes.png), [phone-dark-empty](memory/phone-dark-empty.png), [phone-dark-facts](memory/phone-dark-facts.png), [phone-dark-notes](memory/phone-dark-notes.png).

## KB

The knowledge base: the documents/chunks/sources strip, search results ranked with a score bar and highlighted snippets, the document list with upload, the watched sources, and the empty state.

| | |
|---|---|
| ![KB, desktop-dark.png](kb/desktop-dark.png) | ![KB, desktop-light.png](kb/desktop-light.png) |

All 9: [desktop-dark](kb/desktop-dark.png), [desktop-light](kb/desktop-light.png), [empty-desktop-dark](kb/empty-desktop-dark.png), [empty-desktop-light](kb/empty-desktop-light.png), [empty-phone-dark](kb/empty-phone-dark.png), [empty-phone-light](kb/empty-phone-light.png), [phone-dark](kb/phone-dark.png), [phone-light-documents](kb/phone-light-documents.png), [phone-light](kb/phone-light.png).

## Skills

Skills: skills waiting for approval first, then a row per installed skill with its kind, where it came from and whether its files still match the install, Details, the filter, the catalog, and the in-row confirms for Reject and Remove.

| | |
|---|---|
| ![Skills, skills-desktop-dark.png](skills/skills-desktop-dark.png) | ![Skills, skills-desktop-light.png](skills/skills-desktop-light.png) |

All 13: [skills-catalog-desktop-dark](skills/skills-catalog-desktop-dark.png), [skills-desktop-dark](skills/skills-desktop-dark.png), [skills-desktop-light](skills/skills-desktop-light.png), [skills-details-desktop-dark](skills/skills-details-desktop-dark.png), [skills-empty-desktop-dark](skills/skills-empty-desktop-dark.png), [skills-empty-desktop-light](skills/skills-empty-desktop-light.png), [skills-empty-phone-dark](skills/skills-empty-phone-dark.png), [skills-empty-phone-light](skills/skills-empty-phone-light.png), [skills-installed-desktop-dark](skills/skills-installed-desktop-dark.png), [skills-phone-dark](skills/skills-phone-dark.png), [skills-phone-light](skills/skills-phone-light.png), [skills-reject-confirm-desktop-dark](skills/skills-reject-confirm-desktop-dark.png), [skills-remove-confirm-desktop-dark](skills/skills-remove-confirm-desktop-dark.png).

## Vault

The Code Vault (the pasclaw.dev catalogue of Object Pascal libraries): search, results beside the open entry with its install snippet and Build with this, flagged and blocked entries, and the start, error and empty states.

| | |
|---|---|
| ![Vault, vault-entries-desktop-dark.png](vault/vault-entries-desktop-dark.png) | ![Vault, vault-entries-desktop-light.png](vault/vault-entries-desktop-light.png) |

All 10: [vault-blocked-desktop-dark](vault/vault-blocked-desktop-dark.png), [vault-empty-desktop-light](vault/vault-empty-desktop-light.png), [vault-empty-phone-dark](vault/vault-empty-phone-dark.png), [vault-entries-desktop-dark](vault/vault-entries-desktop-dark.png), [vault-entries-desktop-light](vault/vault-entries-desktop-light.png), [vault-entries-phone-light](vault/vault-entries-phone-light.png), [vault-entry-phone-light](vault/vault-entry-phone-light.png), [vault-error-desktop-dark](vault/vault-error-desktop-dark.png), [vault-start-desktop-dark](vault/vault-start-desktop-dark.png), [vault-start-phone-light](vault/vault-start-phone-light.png).

## Logs

The live log viewer: level chips with counts, the text filter, Pause/Resume, the Live/Paused/Reconnecting pill, the "Live from" divider, and the error state.

| | |
|---|---|
| ![Logs, logs-desktop-dark.png](logs/logs-desktop-dark.png) | ![Logs, logs-desktop-light.png](logs/logs-desktop-light.png) |

All 8: [logs-desktop-dark](logs/logs-desktop-dark.png), [logs-desktop-light](logs/logs-desktop-light.png), [logs-error-desktop-dark](logs/logs-error-desktop-dark.png), [logs-filtered-desktop-dark](logs/logs-filtered-desktop-dark.png), [logs-paused-desktop-dark](logs/logs-paused-desktop-dark.png), [logs-phone-dark](logs/logs-phone-dark.png), [logs-phone-light](logs/logs-phone-light.png), [logs-reconnecting-desktop-dark](logs/logs-reconnecting-desktop-dark.png).

## Checkpoints

Checkpoints: a row per turn that changed files, newest first, with the files tagged Added or Changed, Restore with its confirm, Undo and Redo, and the empty state.

| | |
|---|---|
| ![Checkpoints, checkpoints-list-desktop-dark.png](checkpoints/checkpoints-list-desktop-dark.png) | ![Checkpoints, checkpoints-list-desktop-light.png](checkpoints/checkpoints-list-desktop-light.png) |

All 11: [checkpoints-after-undo-dark](checkpoints/checkpoints-after-undo-dark.png), [checkpoints-desktop-dark](checkpoints/checkpoints-desktop-dark.png), [checkpoints-empty-desktop-dark](checkpoints/checkpoints-empty-desktop-dark.png), [checkpoints-empty-desktop-light](checkpoints/checkpoints-empty-desktop-light.png), [checkpoints-empty-phone-dark](checkpoints/checkpoints-empty-phone-dark.png), [checkpoints-empty-phone-light](checkpoints/checkpoints-empty-phone-light.png), [checkpoints-list-desktop-dark](checkpoints/checkpoints-list-desktop-dark.png), [checkpoints-list-desktop-light](checkpoints/checkpoints-list-desktop-light.png), [checkpoints-list-phone-dark](checkpoints/checkpoints-list-phone-dark.png), [checkpoints-list-phone-light](checkpoints/checkpoints-list-phone-light.png), [checkpoints-phone-light](checkpoints/checkpoints-phone-light.png).

## Workflow

Workflows: staged workflows to approve, a row per saved workflow, the editor (typed step cards, connections, the step settings panel, Fit, the save state) and a run with each step's result, a failed one naming its step.

| | |
|---|---|
| ![Workflow, workflow-editor-desktop-dark.png](workflow/workflow-editor-desktop-dark.png) | ![Workflow, workflow-run-failed-desktop-dark.png](workflow/workflow-run-failed-desktop-dark.png) |

All 10: [workflow-editor-desktop-dark](workflow/workflow-editor-desktop-dark.png), [workflow-editor-phone-light](workflow/workflow-editor-phone-light.png), [workflow-empty-desktop-light](workflow/workflow-empty-desktop-light.png), [workflow-empty-phone-light](workflow/workflow-empty-phone-light.png), [workflow-list-desktop-dark](workflow/workflow-list-desktop-dark.png), [workflow-list-phone-light](workflow/workflow-list-phone-light.png), [workflow-new-desktop-light](workflow/workflow-new-desktop-light.png), [workflow-run-desktop-dark](workflow/workflow-run-desktop-dark.png), [workflow-run-failed-desktop-dark](workflow/workflow-run-failed-desktop-dark.png), [workflow-run-phone-light](workflow/workflow-run-phone-light.png).
