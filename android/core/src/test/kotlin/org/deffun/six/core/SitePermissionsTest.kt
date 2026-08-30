package org.deffun.six.core

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What a site is allowed, which is the fourth thing the two platforms have to agree about.
 *
 * The Mac keeps this in `SixCore` on purpose: the memory, the queue and the rules are the same
 * everywhere and only the type a request arrives as differs. So this is the same suite of questions
 * asked of the Kotlin side — including the ones where the safe answer is no.
 */
class SitePermissionsTest {

    private val directory: File = Files.createTempDirectory("six-permissions").toFile()
    private val profile = UUID.randomUUID()
    private val window = UUID.randomUUID()

    @AfterTest
    fun cleanUp() {
        directory.deleteRecursively()
    }

    private fun permissions() = SitePermissions()

    /** Backed by the settings table, the way the app wires it. */
    private fun permissions(settings: SettingsStore) =
        SitePermissions(settings.sitePermissions) { settings.sitePermissions = it }

    // MARK: The origin an answer is filed under

    /**
     * The default port is left off, because `https://example.com` and `https://example.com:443` are
     * the same origin and filing them apart would ask the same question twice.
     */
    @Test
    fun theOriginIsSchemeHostAndOnlyAPortWorthNaming() {
        assertEquals("https://example.com", SitePermissions.originOf("https://example.com/call?x=1"))
        assertEquals("https://example.com", SitePermissions.originOf("https://example.com:443/"))
        assertEquals("http://example.com", SitePermissions.originOf("http://example.com:80/"))
        assertEquals("https://example.com:8443", SitePermissions.originOf("https://example.com:8443/"))
        assertEquals("http://example.com", SitePermissions.originOf("HTTP://Example.COM/"))
    }

    /** A local page has no host; filing them together is what that origin is. */
    @Test
    fun aFilePageIsFiledUnderItsSchemeAlone() {
        assertEquals("file://", SitePermissions.originOf("file:///tmp/call.html"))
    }

    @Test
    fun somethingWithNoOriginHasNone() {
        assertNull(SitePermissions.originOf(null))
        assertNull(SitePermissions.originOf(""))
        assertNull(SitePermissions.originOf("not a url"))
    }

    // MARK: Asking, and being answered from memory

    @Test
    fun theFirstAskPutsAQuestionOnTheWindow() {
        val permissions = permissions()
        var answered: Boolean? = null

        permissions.decide(listOf(SitePermission.CAMERA), "https://example.com", window, profile) {
            answered = it
        }

        assertNull(answered, "the page was answered before anyone was asked")
        val question = assertNotNull(permissions.question(window))
        assertEquals("example.com", question.host)
        assertEquals(listOf(SitePermission.CAMERA), question.permissions)

        permissions.answer(true, window)

        assertEquals(true, answered)
        assertNull(permissions.question(window), "the question stayed up after being answered")
    }

    @Test
    fun aRememberedAnswerIsGivenWithoutAsking() {
        val permissions = permissions()
        permissions.set(true, SitePermission.MICROPHONE, "https://example.com", profile)

        var answered: Boolean? = null
        permissions.decide(listOf(SitePermission.MICROPHONE), "https://example.com", window, profile) {
            answered = it
        }

        assertEquals(true, answered)
        assertNull(permissions.question(window), "a remembered site was asked about again")
    }

    /**
     * A page that asked for the camera *and* the microphone was asking for a call, and half a call
     * is not what either answer meant.
     */
    @Test
    fun oneNoAmongThemIsANo() {
        val permissions = permissions()
        permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)
        permissions.set(false, SitePermission.MICROPHONE, "https://example.com", profile)

        var answered: Boolean? = null
        permissions.decide(
            listOf(SitePermission.CAMERA, SitePermission.MICROPHONE),
            "https://example.com",
            window,
            profile,
        ) { answered = it }

        assertEquals(false, answered)
    }

    /** One bar, two answers: the whole request is remembered, not the part that was missing. */
    @Test
    fun answeringOneBarWritesEveryPermissionItAskedFor() {
        val permissions = permissions()
        permissions.decide(
            listOf(SitePermission.CAMERA, SitePermission.MICROPHONE),
            "https://example.com",
            window,
            profile,
        ) {}

        permissions.answer(true, window)

        assertEquals(true, permissions.decision(SitePermission.CAMERA, "https://example.com", profile))
        assertEquals(true, permissions.decision(SitePermission.MICROPHONE, "https://example.com", profile))
    }

    /** Nothing to file an answer under is a no, and never a question. */
    @Test
    fun anOpaqueOriginIsDeniedWithoutAsking() {
        val permissions = permissions()
        var answered: Boolean? = null

        permissions.decide(listOf(SitePermission.CAMERA), "", window, profile) { answered = it }
        assertEquals(false, answered)

        permissions.decide(emptyList(), "https://example.com", window, profile) { answered = it }
        assertEquals(false, answered)

        assertNull(permissions.question(window))
    }

    @Test
    fun questionsQueueAndTheBarShowsTheFirst() {
        val permissions = permissions()
        val answers = mutableListOf<Boolean>()

        permissions.decide(listOf(SitePermission.CAMERA), "https://one.example", window, profile) {
            answers.add(it)
        }
        permissions.decide(listOf(SitePermission.MOTION), "https://two.example", window, profile) {
            answers.add(it)
        }

        assertEquals("one.example", permissions.question(window)?.host)
        permissions.answer(false, window)
        assertEquals("two.example", permissions.question(window)?.host)
        permissions.answer(true, window)

        assertEquals(listOf(false, true), answers)
        assertNull(permissions.question(window))
    }

    /**
     * A page suspended on a question that nobody can answer any more has to be told no. Dropping it
     * instead leaves a promise that never lands, and a page that never finds out.
     */
    @Test
    fun aWindowClosingDeniesWhateverItWasAsking() {
        val permissions = permissions()
        var answered: Boolean? = null
        permissions.decide(listOf(SitePermission.CAMERA), "https://example.com", window, profile) {
            answered = it
        }

        permissions.forgetWindow(window)

        assertEquals(false, answered)
        assertNull(permissions.question(window))
        assertNull(
            permissions.decision(SitePermission.CAMERA, "https://example.com", profile),
            "a window closing wrote an answer down",
        )
    }

    /** Answered twice is a crash on some platforms and a lie on the rest. */
    @Test
    fun aQuestionIsOnlyEverAnsweredOnce() {
        val permissions = permissions()
        var count = 0
        permissions.decide(listOf(SitePermission.CAMERA), "https://example.com", window, profile) {
            count += 1
        }

        permissions.answer(true, window)
        permissions.answer(true, window)
        permissions.forgetWindow(window)

        assertEquals(1, count)
    }

    // MARK: Profiles, and changing your mind

    @Test
    fun anAnswerBelongsToOneProfileOnly() {
        val other = UUID.randomUUID()
        val permissions = permissions()
        permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)

        assertNull(permissions.decision(SitePermission.CAMERA, "https://example.com", other))
        assertEquals(2, permissions.let {
            it.set(false, SitePermission.CAMERA, "https://example.com", other)
            it.decisions.size
        })
        assertEquals(
            listOf(profile, other),
            permissions.sites.map { it.profileId },
            "the same origin in two profiles is two rows",
        )
    }

    @Test
    fun takingItBackMakesTheSiteAskAgain() {
        val permissions = permissions()
        permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)
        permissions.forget("https://example.com", profile)

        var answered: Boolean? = null
        permissions.decide(listOf(SitePermission.CAMERA), "https://example.com", window, profile) {
            answered = it
        }

        assertNull(answered, "a forgotten site was answered from memory")
        assertNotNull(permissions.question(window))
    }

    @Test
    fun aProfileGoingTakesItsAnswersWithIt() {
        val other = UUID.randomUUID()
        val permissions = permissions()
        permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)
        permissions.set(true, SitePermission.CAMERA, "https://example.com", other)

        permissions.forgetProfile(profile)

        assertNull(permissions.decision(SitePermission.CAMERA, "https://example.com", profile))
        assertEquals(true, permissions.decision(SitePermission.CAMERA, "https://example.com", other))
    }

    // MARK: What is written down

    @Test
    fun answersSurviveThroughTheSettingsTable() {
        AppDatabase.open(File(directory, AppDatabase.FILE_NAME)).use { database ->
            val settings = SettingsStore(database)
            val permissions = permissions(settings)
            permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)
            permissions.set(false, SitePermission.MOTION, "https://example.com:8443", profile)

            val reopened = permissions(settings)
            assertEquals(2, reopened.decisions.size)
            assertEquals(true, reopened.decision(SitePermission.CAMERA, "https://example.com", profile))
            assertEquals(
                false,
                reopened.decision(SitePermission.MOTION, "https://example.com:8443", profile),
            )
        }
    }

    /**
     * The blob is a `JSONEncoder` document that happens to live in SQLite, so its UUIDs follow the
     * snapshot's convention — uppercase — and not the schema's. Backwards, and a profile silently
     * gets a second, empty set of answers.
     */
    @Test
    fun theStoredBlobIsTheMacsShape() {
        AppDatabase.open(File(directory, AppDatabase.FILE_NAME)).use { database ->
            val settings = SettingsStore(database)
            permissions(settings).set(true, SitePermission.CAMERA, "https://example.com", profile)

            val json = assertNotNull(settings["permissions.sites"])
            assertContains(json, profile.toString().uppercase())
            assertFalse(json.contains(profile.toString().lowercase()), "a lowercase UUID was written")
            assertContains(json, "\"profileID\"")
            assertContains(json, "\"camera\"")
            assertContains(json, "\"isAllowed\"")
        }
    }

    /** An absent setting and an empty one mean the same thing; the row goes rather than holding `[]`. */
    @Test
    fun emptyingTheListRemovesTheRow() {
        AppDatabase.open(File(directory, AppDatabase.FILE_NAME)).use { database ->
            val settings = SettingsStore(database)
            val permissions = permissions(settings)
            permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)
            permissions.forgetAll()

            assertNull(settings["permissions.sites"])
        }
    }

    /** The point of a private profile is that nothing about it survives it. */
    @Test
    fun aPrivateProfilesAnswersAreNeverWrittenDown() {
        AppDatabase.open(File(directory, AppDatabase.FILE_NAME)).use { database ->
            val settings = SettingsStore(database)
            val private = UUID.randomUUID()
            val permissions = permissions(settings)
            permissions.isPrivate = { it == private }

            permissions.set(true, SitePermission.CAMERA, "https://example.com", private)
            permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)

            // In memory for as long as the profile lives...
            assertEquals(true, permissions.decision(SitePermission.CAMERA, "https://example.com", private))
            // ...and gone from the file.
            val reopened = permissions(settings)
            assertNull(reopened.decision(SitePermission.CAMERA, "https://example.com", private))
            assertEquals(true, reopened.decision(SitePermission.CAMERA, "https://example.com", profile))
        }
    }

    @Test
    fun changingYourMindReplacesTheAnswerRatherThanAddingOne() {
        val permissions = permissions()
        permissions.set(true, SitePermission.CAMERA, "https://example.com", profile)
        permissions.set(false, SitePermission.CAMERA, "https://example.com", profile)

        assertEquals(1, permissions.decisions.size)
        assertEquals(false, permissions.decision(SitePermission.CAMERA, "https://example.com", profile))
        assertTrue(permissions.sites.size == 1)
    }
}
