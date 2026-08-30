package org.deffun.six.core

/**
 * The `settings` table: keys and strings, and nothing that knows what any of them mean.
 *
 * That is the shape the Mac's own `SettingsStore` was untangled into — each typed accessor lives
 * beside the type it decodes, and what is left here knows only keys — and it is what makes the table
 * safe to share. A setting Android has never heard of is a row it reads, ignores and leaves alone,
 * rather than a decode failure in the middle of launch.
 */
class SettingsStore(private val database: AppDatabase) {

    operator fun get(key: String): String? =
        database.prepare("""SELECT "value" FROM "settings" WHERE "key" = ?""") {
            it.bindText(1, key)
            if (it.step()) it.getText(0) else null
        }

    /**
     * An explicit upsert, and not because the schema forgot to provide one.
     *
     * `"key" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE` reads as though a repeated insert
     * replaces the row. It does not: a conflict clause attaches to the constraint it follows, so
     * that `ON CONFLICT REPLACE` belongs to `NOT NULL`, and the primary key keeps SQLite's default
     * ABORT. A second insert on the same key raises `UNIQUE constraint failed` — which is how this
     * was found. The whole schema is written this way, so the same is true of every table here.
     */
    operator fun set(key: String, value: String) {
        database.prepare(
            """
            INSERT INTO "settings" ("key", "value") VALUES (?, ?)
            ON CONFLICT("key") DO UPDATE SET "value" = excluded."value"
            """.trimIndent(),
        ) {
            it.bindText(1, key)
            it.bindText(2, value)
            it.step()
        }
    }

    fun remove(key: String) {
        database.prepare("""DELETE FROM "settings" WHERE "key" = ?""") {
            it.bindText(1, key)
            it.step()
        }
    }

    fun all(): Map<String, String> {
        val settings = LinkedHashMap<String, String>()
        database.prepare("""SELECT "key", "value" FROM "settings" ORDER BY "key"""") {
            while (it.step()) settings[it.getText(0)] = it.getText(1)
        }
        return settings
    }
}
