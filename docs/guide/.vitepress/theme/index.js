import {h} from 'vue'
import DefaultTheme from 'vitepress/theme-without-fonts'

import WindowFigure from './WindowFigure.vue'
import './custom.css'

// The default theme, repainted from the application's own design and given one
// thing of its own. Nothing is replaced: the guide is prose and a sidebar, which
// is what the theme already is, so what it needs from us is the palette, the
// type and — on the home page — a picture of the product under the hero.
//
// `theme-without-fonts` is that theme minus its own Inter and Punctuation
// webfonts: custom.css brings the Inter it uses itself, as the stand-in for the
// system font on devices that do not have it.
//
// `custom.css` and `fonts/` carry the same tokens as `site/styles.css`; when
// they change, they change in both places.
export default {
    extends: DefaultTheme,
    Layout: () => h(DefaultTheme.Layout, null, {
        'home-hero-after': () => h(WindowFigure),
    }),
}
