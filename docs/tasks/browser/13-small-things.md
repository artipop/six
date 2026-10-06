# 13. Small things — one pass

Seven items from [todo.md](../../todo.md), none of them more than an afternoon, none needing a decision that is not
written here. Each is its own commit; strings go through the String Catalog in English and Russian, and the guide
gets a line in both languages where a person would look for it.

1. **Forget one site.** Drop a single host's cookies and storage (`WKWebsiteDataStore.fetchDataRecords` →
   `removeData(ofTypes:for:)`). Clearing a whole profile is the only option today, and it takes every login with it.
   The place is the site menu under the lock, beside "forget this site's choices".
2. **A way back to the start page** after navigating — a "home" affordance, or `⌘⇧H`. Check the key against
   `KeyBindings` and the system's own first (AGENTS.md: `defaults read com.apple.symbolichotkeys`).
3. **A window whose address is a download re-downloads it on every launch.** `closeIfOnlyCarriedALink` closes the
   window a link opened, not the one somebody typed the address into.
4. **Per-site user-agent overrides** through `WKWebView.customUserAgent`, for sites that sniff wrongly even at
   Safari's string. A row per site in the same place as permissions; no list of presets.
5. **Every model from the welcome.** The welcome's provider step knows its own four doors; a custom ACP agent and
   Private Cloud Compute are not offered there, though both exist in Configuration ▸ Assistant.
6. **A Help menu that opens the guide** — the page for the pane in front, in the interface language — and a `?`
   on each configuration pane going to the same place. Online only for now; a bundled copy is a separate question.
7. **Group Tabs by Meaning off for a new install.** The switch in Configuration (`ConfigurationPageView`, "Group
   Tabs by Meaning") is on by default today. Off for a home that has never been launched; an existing one keeps
   what it has — check how the default is read, so that "never set" and "set to on" are told apart.

Take them in this order and stop wherever the session ends: each is finished or not started.

Not in this pass, because each needs a design first: the two switches in Configuration that mean different sizes of
thing, and the ring's three-key arrows — both in [21](../design/21-open-design-questions.md).
