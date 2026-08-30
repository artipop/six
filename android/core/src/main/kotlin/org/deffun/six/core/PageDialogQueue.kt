package org.deffun.six.core

import java.util.UUID

/** What a page is asking for. */
sealed interface PageDialogKind {
    data object Alert : PageDialogKind

    data object Confirm : PageDialogKind

    data class Prompt(val defaultText: String) : PageDialogKind

    data class File(
        val allowsMultiple: Boolean,
        /** What the input said it would take, as MIME types. Empty means anything. */
        val acceptTypes: List<String>,
    ) : PageDialogKind
}

/** And what it was told. */
sealed interface PageDialogAnswer {
    data class Ok(val text: String = "") : PageDialogAnswer

    data object Cancel : PageDialogAnswer

    data class Files(val uris: List<String>) : PageDialogAnswer
}

data class PageDialogRequest(
    val host: String,
    val message: String,
    val kind: PageDialogKind,
    val id: UUID = UUID.randomUUID(),
)

/**
 * `alert()`, `confirm()`, `prompt()` and `<input type="file">`, and the one place a phone can answer
 * them.
 *
 * The Mac gives each of these a sheet on the window the page lives in. A phone has one window and no
 * sheet to hang off a column, so the request goes into a queue the window watches, the answer comes
 * back here, and the page's JavaScript — suspended by the engine all the while, as `alert()` has
 * always been — carries on. One at a time: a second page asking waits for the first to be answered.
 *
 * **Every request must be answered exactly once.** A `JsResult` left hanging suspends that page's
 * JavaScript forever, and a file chooser callback never invoked makes that `<input type="file">`
 * permanently dead — the engine will not ask again. So [resolve] is the only way out and [cancelAll]
 * exists for the cases where nobody will.
 */
class PageDialogQueue {

    /** The question on screen, if there is one. */
    var current: PageDialogRequest? = null
        private set

    private var answer: ((PageDialogAnswer) -> Unit)? = null
    private val waiting = ArrayDeque<Pair<PageDialogRequest, (PageDialogAnswer) -> Unit>>()

    /** Told when the question on screen changes, for a front end that does not watch this object. */
    var onChanged: (() -> Unit)? = null

    fun ask(request: PageDialogRequest, answer: (PageDialogAnswer) -> Unit) {
        if (current == null) {
            current = request
            this.answer = answer
        } else {
            waiting.addLast(request to answer)
        }
        onChanged?.invoke()
    }

    /**
     * Called by the view when the person has answered *this* request.
     *
     * The id is not ceremony. One answer arrives twice — dismissing a dialog and running the button
     * that dismissed it are two events, on both toolkits — and by the time the second arrives the
     * next question has already been promoted. Answering "whatever is current" would then answer the
     * next one without anyone having seen it, which a test here does catch and a person would not.
     */
    fun resolve(id: UUID, value: PageDialogAnswer) {
        if (current?.id != id) return
        val callback = answer ?: return
        current = null
        answer = null
        callback(value)

        val next = waiting.removeFirstOrNull()
        if (next != null) {
            current = next.first
            answer = next.second
        }
        onChanged?.invoke()
    }

    /**
     * Nobody is going to answer these — the window closed, or the page went away with them queued.
     *
     * Cancelling rather than dropping, because a request that is merely forgotten leaves a page
     * suspended on a promise that never lands, or a file input that can never be opened again.
     */
    fun cancelAll() {
        val pending = buildList {
            answer?.let { add(it) }
            for ((_, callback) in waiting) add(callback)
        }
        current = null
        answer = null
        waiting.clear()
        for (callback in pending) callback(PageDialogAnswer.Cancel)
        onChanged?.invoke()
    }
}
