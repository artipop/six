<script setup>
import {computed} from 'vue'
import {useData} from 'vitepress'

// The picture belongs under the hero rather than in the page body, which is
// where markdown on a home layout would land it — below the feature cards, and
// below the fold. `home-hero-after` is the theme's own seam for exactly this.

const {lang} = useData()

const legend = computed(() => lang.value.startsWith('ru')
    ? 'вкладки в цветных группах · адрес и страницы рядом · строка ассистента под ними'
    : 'tabs in coloured groups · the address field and two pages side by side · the assistant line under them')
</script>

<template>
    <div class="win-figure">
        <!-- Decoration: named by the legend beside it, so there is nothing here
             for a screen reader to gain by walking a dozen empty spans. -->
        <div class="win" aria-hidden="true">
            <div class="win-tabs">
                <span class="win-dots"><i></i><i></i><i></i></span>
                <span class="win-group" style="--group: 21, 130, 240"></span>
                <span class="win-tab on"></span>
                <span class="win-tab"></span>
                <span class="win-group" style="--group: 244, 124, 52"></span>
                <span class="win-tab"></span>
            </div>
            <div class="win-bar">
                <span class="win-address"></span>
                <span class="win-shield"></span>
            </div>
            <div class="win-split">
                <div class="win-page on">
                    <span class="win-line head"></span>
                    <span class="win-line w-90"></span>
                    <span class="win-line w-75"></span>
                    <span class="win-line w-90"></span>
                    <span class="win-line w-60"></span>
                </div>
                <div class="win-page">
                    <span class="win-line head"></span>
                    <span class="win-line w-60"></span>
                    <span class="win-line w-90"></span>
                    <span class="win-line w-75"></span>
                    <span class="win-line w-90"></span>
                </div>
            </div>
            <div class="win-ask"></div>
        </div>
        <p class="win-legend">{{ legend }}</p>
    </div>
</template>
