import DefaultTheme from 'vitepress/theme-without-fonts'

import './custom.css'

// The default theme, repainted in deffun's palette. Nothing is replaced: the
// guide is prose and a sidebar, which is what the theme already is, so what it
// needs from us is the palette and the two typefaces — and those are CSS
// variables.
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
// describes.
export default DefaultTheme
