import {defineConfig} from 'vite'

// `BASE` is where the page is served from: `/` standing alone, `/vi/` when
// deffun (../../deffun) puts it beside the other products. The guide is always
// `BASE + 'docs/'`.
export default defineConfig({
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
})
