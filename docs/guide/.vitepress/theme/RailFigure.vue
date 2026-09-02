<script setup>
import {computed} from 'vue'
import {useData} from 'vitepress'

// The picture belongs under the hero rather than in the page body, which is
// where markdown on a home layout would land it — below the feature cards, and
// below the fold. `home-hero-after` is the theme's own seam for exactly this.

const {lang} = useData()

// The caption is the machine naming the parts, so it is one line per language
// rather than a paragraph to translate.
const legend = computed(() => lang.value.startsWith('ru')
    ? 'одна строка сверху · окно — это страница · вбок по ленте · вверх-вниз по рабочим столам'
    : 'one bar at the top · a window is a page · sideways along the rail · up and down through workspaces')
</script>

<template>
    <div class="rail-figure">
        <!-- Decoration: named by the legend beside it, so there is nothing here
             for a screen reader to gain by walking a dozen empty spans. -->
        <div class="rail" aria-hidden="true">
            <div class="rail-bar">
                <span class="rail-profile"></span>
                <span class="rail-address"></span>
                <span class="rail-pips"><i></i><i class="on"></i><i></i></span>
            </div>
            <div class="rail-strip">
                <div class="rail-col">
                    <span class="rail-line w-60"></span>
                    <span class="rail-line w-90"></span>
                    <span class="rail-line w-75"></span>
                    <span class="rail-line w-90"></span>
                    <span class="rail-line w-40"></span>
                </div>
                <div class="rail-col is-focused">
                    <span class="rail-line"></span>
                    <span class="rail-line w-90"></span>
                    <span class="rail-line w-75"></span>
                    <span class="rail-line w-90"></span>
                    <span class="rail-line w-60"></span>
                    <span class="rail-line w-40"></span>
                </div>
                <div class="rail-col">
                    <span class="rail-line w-60"></span>
                    <span class="rail-line w-75"></span>
                    <span class="rail-line w-90"></span>
                    <span class="rail-line w-40"></span>
                </div>
            </div>
        </div>
        <p class="rail-legend">{{ legend }}</p>
    </div>
</template>

