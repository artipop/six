# When a page does not open

When an address fails to load, an empty window is replaced by a **This page didn't open** screen. It shows:

- the site's address (you can select and copy it);
- an explanation;
- **Try Again**, which loads the same address once more;
- in small grey type, the system's message and error code. It is what to paste into a search or a support message.

## The explanations

| explanation | what happened |
|---|---|
| **This address could not be reached.** | the site is not answering, the address is mistyped, or there is no network |
| **This site's certificate could not be traced back to an authority this Mac trusts…** | the certificate was issued by an authority that is not trusted. A **Certificates** link appears beside the button; it opens [Configuration](configuration.md) |
| **This site's certificate was issued by …. The authority is on the list but is not trusted until you turn it on.** | Savoia has that authority, but it is switched off. Beside **Try Again** there is a **Trust …** button |

The **Trust …** button does what the switch in **Configuration ▸ Privacy ▸ Certificates** does: it turns the authority on
and retries the load at once. The same switch turns it off again. More on the page [Certificates](certificates.md).

The next successful load in that tab removes the screen.
