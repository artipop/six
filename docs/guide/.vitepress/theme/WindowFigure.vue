<script setup>
import {computed} from 'vue'
import {useData} from 'vitepress'

// The picture belongs under the hero rather than in the page body, which is
// where markdown on a home layout would land it — below the feature cards, and
// below the fold. `home-hero-after` is the theme's own seam for exactly this.

const {lang} = useData()

const legend = computed(() => lang.value.startsWith('ru')
    ? 'вкладки в цветных группах · закреплённая слева · две страницы рядом'
    : 'tabs in coloured groups · a pinned one on the left · two pages side by side')
</script>

<template>
    <div class="shot-figure">
        <!-- Decoration: named by the legend beside it, so there is nothing here
             for a screen reader to gain by walking a dozen empty spans. -->
        <div class="shot" aria-hidden="true">
            <div class="shot-tabs">
                <span class="shot-pin"></span>
                <span class="shot-group g-blue"><b></b><i class="on"></i><i></i></span>
                <span class="shot-group g-orange"><b></b><i></i><i></i><i></i></span>
                <span class="shot-group g-green"><b></b><i></i></span>
            </div>
            <div class="shot-bar">
                <span class="shot-nav"></span>
                <span class="shot-address"></span>
                <span class="shot-profile"></span>
            </div>
            <div class="shot-pages">
                <div class="shot-page">
                    <span class="shot-line head"></span>
                    <span class="shot-line w-90"></span>
                    <span class="shot-line w-75"></span>
                    <span class="shot-line w-90"></span>
                    <span class="shot-line w-60"></span>
                    <span class="shot-line w-40"></span>
                </div>
                <div class="shot-page">
                    <span class="shot-line head"></span>
                    <span class="shot-line w-75"></span>
                    <span class="shot-line w-90"></span>
                    <span class="shot-line w-60"></span>
                    <span class="shot-line w-90"></span>
                    <span class="shot-line w-40"></span>
                </div>
            </div>
        </div>
        <p class="shot-legend">{{ legend }}</p>
    </div>
</template>
