import {h} from 'vue'
import DefaultTheme from 'vitepress/theme-without-fonts'

import RailFigure from './RailFigure.vue'
import './custom.css'

// The default theme, repainted in deffun's palette and given one thing of its
// own. Nothing is replaced: the guide is prose and a sidebar, which is what the
// theme already is, so what it needs from us is the palette, the two typefaces
// and — on the home page — a picture of the product under the hero.
//
// `theme-without-fonts` is that theme minus its own Inter and Punctuation
// webfonts: a megabyte of woff2 nobody would see, since custom.css names the
// company's own faces instead.
//
// `custom.css` and `fonts/` are **copies** of the ones in the XCIII guide
// (`xciii/docs/guide/.vitepress/theme/`), not imports of them. The XXVI guide
// imports the original, because it lives in the same repository; this one does
// not, and a site that only builds when a sibling checkout happens to be there
// is worse than a duplicated stylesheet. When the tokens change, they change in
// two places — that is the price of the guide living with the browser it
// describes. What is *not* a copy is everything under "corners" and "the rail":
// those are this product's own, and the XCIII guide must not grow them.
export default {
    extends: DefaultTheme,
    Layout: () => h(DefaultTheme.Layout, null, {
        'home-hero-after': () => h(RailFigure),
    }),
}
