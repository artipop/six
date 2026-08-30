package org.deffun.six.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The four dialogs a page can put up.
 *
 * Everything here is about a promise landing exactly once. A `JsResult` left hanging suspends that
 * page's JavaScript forever; a file chooser callback never invoked makes that `<input type="file">`
 * permanently dead, because the engine will not ask again. Neither failure looks like a crash — the
 * page simply stops — so the queue is the thing that has to be right.
 */
class PageDialogQueueTest {

    private fun alert(host: String = "example.com", message: String = "hello") =
        PageDialogRequest(host, message, PageDialogKind.Alert)

    @Test
    fun theFirstQuestionGoesUpAndIsAnswered() {
        val queue = PageDialogQueue()
        var answer: PageDialogAnswer? = null

        queue.ask(alert()) { answer = it }

        val current = assertNotNull(queue.current)
        assertEquals("example.com", current.host)
        assertNull(answer, "the page was answered before anyone was asked")

        queue.resolve(current.id, PageDialogAnswer.Ok())

        assertEquals(PageDialogAnswer.Ok(), answer)
        assertNull(queue.current)
    }

    /**
     * The one that bites on both platforms: dismissing a dialog and running the button that
     * dismissed it are two events, so this arrives twice for one answer. Taking the next question
     * off the queue on the second would cancel it without anyone having seen it.
     */
    @Test
    fun answeringTwiceDoesNotEatTheNextQuestion() {
        val queue = PageDialogQueue()
        val answers = mutableListOf<PageDialogAnswer>()

        queue.ask(alert(host = "one.example")) { answers.add(it) }
        queue.ask(alert(host = "two.example")) { answers.add(it) }

        val first = assertNotNull(queue.current).id
        queue.resolve(first, PageDialogAnswer.Ok())
        queue.resolve(first, PageDialogAnswer.Ok()) // the dismissal, arriving after the button

        assertEquals(1, answers.size, "the second question was answered by a stray dismissal")
        assertEquals("two.example", queue.current?.host, "the second question was thrown away")

        queue.resolve(assertNotNull(queue.current).id, PageDialogAnswer.Cancel)
        assertEquals(listOf<PageDialogAnswer>(PageDialogAnswer.Ok(), PageDialogAnswer.Cancel), answers)
        assertNull(queue.current)
    }

    /** An answer for a question that is no longer on screen is not an answer for the one that is. */
    @Test
    fun anAnswerForAnotherQuestionIsIgnored() {
        val queue = PageDialogQueue()
        var answer: PageDialogAnswer? = null
        queue.ask(alert()) { answer = it }

        queue.resolve(java.util.UUID.randomUUID(), PageDialogAnswer.Ok())

        assertNull(answer)
        assertNotNull(queue.current)
    }

    @Test
    fun aSecondPageWaitsForTheFirst() {
        val queue = PageDialogQueue()
        val order = mutableListOf<String>()

        queue.ask(alert(host = "one.example")) { order.add("one") }
        queue.ask(alert(host = "two.example")) { order.add("two") }
        queue.ask(alert(host = "three.example")) { order.add("three") }

        assertEquals("one.example", queue.current?.host)
        queue.resolve(assertNotNull(queue.current).id, PageDialogAnswer.Ok())
        assertEquals("two.example", queue.current?.host)
        queue.resolve(assertNotNull(queue.current).id, PageDialogAnswer.Ok())
        assertEquals("three.example", queue.current?.host)
        queue.resolve(assertNotNull(queue.current).id, PageDialogAnswer.Ok())

        assertEquals(listOf("one", "two", "three"), order)
        assertNull(queue.current)
    }

    @Test
    fun aPromptCarriesItsDefaultAndItsAnswer() {
        val queue = PageDialogQueue()
        var answer: PageDialogAnswer? = null

        queue.ask(
            PageDialogRequest("example.com", "Your name?", PageDialogKind.Prompt("Anonymous")),
        ) { answer = it }

        val kind = assertNotNull(queue.current?.kind as? PageDialogKind.Prompt)
        assertEquals("Anonymous", kind.defaultText)

        queue.resolve(assertNotNull(queue.current).id, PageDialogAnswer.Ok("Artem"))
        assertEquals(PageDialogAnswer.Ok("Artem"), answer)
    }

    @Test
    fun aFileRequestCarriesWhatTheInputWouldTake() {
        val queue = PageDialogQueue()
        var answer: PageDialogAnswer? = null

        queue.ask(
            PageDialogRequest(
                "example.com",
                "is asking for a file.",
                PageDialogKind.File(allowsMultiple = true, acceptTypes = listOf("image/*")),
            ),
        ) { answer = it }

        val kind = assertNotNull(queue.current?.kind as? PageDialogKind.File)
        assertTrue(kind.allowsMultiple)
        assertEquals(listOf("image/*"), kind.acceptTypes)

        queue.resolve(
            assertNotNull(queue.current).id,
            PageDialogAnswer.Files(listOf("content://a", "content://b")),
        )
        assertEquals(PageDialogAnswer.Files(listOf("content://a", "content://b")), answer)
    }

    /**
     * A window closing with questions queued. Cancelling rather than dropping, because a forgotten
     * request is a page suspended forever, or a file input that can never be opened again.
     */
    @Test
    fun nothingIsEverLeftUnanswered() {
        val queue = PageDialogQueue()
        val answers = mutableListOf<PageDialogAnswer>()

        queue.ask(alert(host = "one.example")) { answers.add(it) }
        queue.ask(alert(host = "two.example")) { answers.add(it) }
        queue.ask(alert(host = "three.example")) { answers.add(it) }

        queue.cancelAll()

        assertEquals(3, answers.size, "a queued request was dropped rather than cancelled")
        assertTrue(answers.all { it == PageDialogAnswer.Cancel })
        assertNull(queue.current)
    }

    @Test
    fun cancellingAnEmptyQueueDoesNothing() {
        val queue = PageDialogQueue()
        var changes = 0
        queue.onChanged = { changes += 1 }

        queue.cancelAll()

        assertNull(queue.current)
        assertEquals(1, changes)
    }

    /** A front end that does not watch the object is told when the question on screen changes. */
    @Test
    fun theViewIsToldWhenTheQuestionChanges() {
        val queue = PageDialogQueue()
        var changes = 0
        queue.onChanged = { changes += 1 }

        queue.ask(alert()) {}
        queue.resolve(assertNotNull(queue.current).id, PageDialogAnswer.Ok())

        assertEquals(2, changes)
    }
}
