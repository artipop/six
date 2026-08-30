package org.deffun.six.app

import android.Manifest
import android.webkit.PermissionRequest
import org.deffun.six.core.SitePermission

/**
 * The translation between what a page asks Android for and what six files an answer under.
 *
 * Everything past this file is `SitePermissions` in `:core`, which is the Mac's own code and knows
 * nothing about either platform's vocabulary.
 */
object SitePermissionBridge {

    /** What the page asked for, in six's terms. Anything unrecognised is left out and so denied. */
    fun permissions(resources: Array<out String>): List<SitePermission> =
        resources.mapNotNull {
            when (it) {
                PermissionRequest.RESOURCE_VIDEO_CAPTURE -> SitePermission.CAMERA
                PermissionRequest.RESOURCE_AUDIO_CAPTURE -> SitePermission.MICROPHONE
                else -> null
            }
        }.distinct()

    /** And back, to hand the page exactly what it asked for and nothing more. */
    fun resources(permissions: List<SitePermission>): Array<String> =
        permissions.mapNotNull {
            when (it) {
                SitePermission.CAMERA -> PermissionRequest.RESOURCE_VIDEO_CAPTURE
                SitePermission.MICROPHONE -> PermissionRequest.RESOURCE_AUDIO_CAPTURE
                // Motion sensors never arrive here: Chromium does not gate `DeviceMotionEvent`
                // behind `onPermissionRequest` the way WebKit gates it behind its own callback. six
                // keeps the case because the answer travels in `state.json` from a Mac that does.
                SitePermission.MOTION -> null
            }
        }.toTypedArray()

    /** The app-level permission each one needs before a page can be granted it. */
    fun systemPermissions(permissions: List<SitePermission>): Set<String> =
        permissions.mapNotNull {
            when (it) {
                SitePermission.CAMERA -> Manifest.permission.CAMERA
                SitePermission.MICROPHONE -> Manifest.permission.RECORD_AUDIO
                SitePermission.MOTION -> null
            }
        }.toSet()
}
