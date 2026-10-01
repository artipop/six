import {existsSync, readFileSync} from 'node:fs'
import {defineConfig, loadEnv} from 'vite'

// A profile is who the page is published for — deffun, or the personal site —
// and it is a Vite mode: `.env.<profile>` holds the values, and
// `profiles/<profile>/<name>.html` fills the `<!--profile:name-->` blocks of
// index.html (requisites, price). A profile with no file for a block shows
// nothing there. The pages stay otherwise identical.
function profile(mode) {
    const origin = loadEnv(mode, import.meta.dirname, 'VITE_').VITE_ORIGIN
    return {
        name: 'profile',
        transformIndexHtml: {
            order: 'pre',
            handler: (html) => html
                .replace(/<!--\s*profile:([\w-]+)\s*-->/g, (_, block) => {
                    const file = `${import.meta.dirname}/profiles/${mode}/${block}.html`
                    return existsSync(file) ? readFileSync(file, 'utf8').replace(/\n$/, '') : ''
                })
                // Without a domain there is nothing for a canonical address to say.
                .replace(/^.*%VITE_ORIGIN%.*\n/gm, origin ? '$&' : ''),
        },
    }
}

// `BASE` is where the page is served from: `/` standing alone, `/xciii/` when
// deffun (../../deffun) puts it beside the other products. The guide is always
// `BASE + 'docs/'`.

// `BASE` is where the page is served from: `/` standing alone, `/savoia/` when
// deffun (../../deffun) puts it beside the other products. The guide is always
// `BASE + 'docs/'`.
export default defineConfig(({mode}) => ({
    plugins: [profile(mode)],

    base: process.env.BASE ?? '/',

    // In dev /docs/ is a second server (the guide, port 5176), so the link to it
    // would be a 404 exactly where it is being written. `ws` because the guide's
    // hot reload talks over a socket on this path too.
    server: {
        proxy: {
            '/docs': {target: 'http://localhost:5176', ws: true},
        },
    },

    // After `build:all` the guide is a real folder under dist/docs, which is what
    // preview exists to show; an empty object turns the proxy inheritance off.
    preview: {
        proxy: {},
    },
}))
