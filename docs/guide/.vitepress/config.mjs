import {defineConfig} from 'vitepress'

// The VI user guide as a site — the browser this repository builds, described
// for the person using it rather than for the person changing it. Everything
// else in `docs/` is the second kind and stays out of the publication: the
// VitePress root is this folder, so nothing above it can be reached.
//
// VitePress for the reasons the other two deffun guides picked it: it is Vite,
// and Shiki colours the code at build time, so a key combination or a shell
// line costs the reader no JavaScript.
//
// Two locales, page for page: Russian at the root, English under /en/. The
// application itself speaks both (see docs/localization.md), so a guide that
// spoke one would be describing buttons the reader cannot find.
//
// **The product is called VI here and `six` in the application.** That is not a
// slip: the name on deffun's shelf is a Roman numeral, beside XCIII and XXVI,
// and the name in the menu bar is the one the app was built under. Where a page
// quotes the interface — "Set six as Default Browser…", the folder under
// Application Support — it says `six`, because that is what is on the screen.

const ru = {
    label: 'Русский',
    lang: 'ru-RU',
    titleTemplate: ':title — руководство VI',
    description: 'Руководство пользователя VI: лента окон вместо вкладок, блокировка рекламы, ассистент и агенты.',

    themeConfig: {
        siteTitle: 'VI · Руководство',

        nav: [
            {text: 'Начало', link: '/start'},
            {text: 'Лента', link: '/layout'},
            {text: 'Приватность', link: '/blocking'},
            {text: 'Агенты', link: '/agents'},
            {text: 'Клавиши', link: '/hotkeys'},
        ],

        sidebar: [
            {
                text: 'Начало',
                items: [
                    {text: 'Первый запуск', link: '/start'},
                    {text: 'Лента и рабочие столы', link: '/layout'},
                    {text: 'Окна, ссылки и загрузки', link: '/windows'},
                    {text: 'Горячие клавиши', link: '/hotkeys'},
                ],
            },
            {
                text: 'Каждый день',
                items: [
                    {text: 'Профили и приватное окно', link: '/profiles'},
                    {text: 'Закладки и история', link: '/bookmarks'},
                    {text: 'Перевод страниц', link: '/translate'},
                ],
            },
            {
                text: 'Приватность',
                items: [
                    {text: 'Реклама и трекеры', link: '/blocking'},
                    {text: 'Разрешения сайтов', link: '/permissions'},
                    {text: 'Сертификаты', link: '/certificates'},
                ],
            },
            {
                text: 'Ассистент и агенты',
                items: [
                    {text: 'Ассистент ⌘K', link: '/assistant'},
                    {text: 'Агенты ⌘⇧A', link: '/agents'},
                    {text: 'Глубокое исследование', link: '/research'},
                    {text: 'MCP-приложения', link: '/apps'},
                ],
            },
            {
                text: 'Ещё',
                items: [
                    {text: 'Расширения', link: '/extensions'},
                    {text: 'Инструменты разработчика', link: '/devtools'},
                ],
            },
        ],

        // Everything a reader sees is Russian, the theme's own furniture
        // included — its defaults are English.
        outline: {level: [2, 3], label: 'На этой странице'},
        docFooter: {prev: 'Назад', next: 'Дальше'},
        returnToTopLabel: 'Наверх',
        sidebarMenuLabel: 'Разделы',
        langMenuLabel: 'Сменить язык',
        darkModeSwitchLabel: 'Оформление',
        lightModeSwitchTitle: 'Светлая тема',
        darkModeSwitchTitle: 'Тёмная тема',
        lastUpdatedText: 'Обновлено',

        footer: {
            message: 'Руководство пользователя VI',
            copyright: '© 2026 deffun',
        },

        notFound: {
            title: 'Такой страницы нет',
            quote: 'Возможно, раздел переехал — он должен быть в списке слева.',
            linkText: 'К началу руководства',
        },
    },
}

const en = {
    label: 'English',
    lang: 'en-US',
    link: '/en/',
    titleTemplate: ':title — the VI guide',
    description: 'The VI user guide: a strip of windows instead of tabs, blocking, the assistant and the agents.',

    themeConfig: {
        siteTitle: 'VI · Guide',

        nav: [
            {text: 'Start', link: '/en/start'},
            {text: 'The strip', link: '/en/layout'},
            {text: 'Privacy', link: '/en/blocking'},
            {text: 'Agents', link: '/en/agents'},
            {text: 'Keys', link: '/en/hotkeys'},
        ],

        sidebar: [
            {
                text: 'Getting started',
                items: [
                    {text: 'First launch', link: '/en/start'},
                    {text: 'The strip and workspaces', link: '/en/layout'},
                    {text: 'Windows, links and downloads', link: '/en/windows'},
                    {text: 'Keyboard shortcuts', link: '/en/hotkeys'},
                ],
            },
            {
                text: 'Every day',
                items: [
                    {text: 'Profiles and private windows', link: '/en/profiles'},
                    {text: 'Bookmarks and history', link: '/en/bookmarks'},
                    {text: 'Translating a page', link: '/en/translate'},
                ],
            },
            {
                text: 'Privacy',
                items: [
                    {text: 'Ads and trackers', link: '/en/blocking'},
                    {text: 'Site permissions', link: '/en/permissions'},
                    {text: 'Certificates', link: '/en/certificates'},
                ],
            },
            {
                text: 'The assistant and the agents',
                items: [
                    {text: 'The ⌘K assistant', link: '/en/assistant'},
                    {text: 'Agents (⌘⇧A)', link: '/en/agents'},
                    {text: 'Deep research', link: '/en/research'},
                    {text: 'MCP apps', link: '/en/apps'},
                ],
            },
            {
                text: 'More',
                items: [
                    {text: 'Extensions', link: '/en/extensions'},
                    {text: 'Developer tools', link: '/en/devtools'},
                ],
            },
        ],

        outline: {level: [2, 3], label: 'On this page'},

        footer: {
            message: 'The VI user guide',
            copyright: '© 2026 deffun',
        },

        notFound: {
            title: 'No such page',
            quote: 'The section may have moved — it should be in the list on the left.',
            linkText: 'To the start of the guide',
        },
    },
}

export default defineConfig({
    title: 'VI',

    // The product is a screen, so the screen theme is the one a reader arrives
    // in — the same decision the landing page and the other two guides make.
    appearance: 'dark',
    lastUpdated: true,

    // Addresses keep their `.html`, for the reason the XCIII guide states: a
    // clean URL needs the host to strip the extension, and a guide that 404s
    // depending on where it was uploaded is worse than an ugly address.
    cleanUrls: false,

    // Published beside the other two guides, inside the landing's own dist, so
    // that a deploy stays one directory. `build:all` in xciii/site runs the
    // landing first (it empties dist/), then the XCIII guide (it empties
    // dist/docs), then XXVI and this one, which live inside it.
    //
    // The path leaves this repository, which the other two do not have to do:
    // the guide lives with the browser, the site lives next door. Building it
    // wants both checkouts side by side under one folder.
    base: '/docs/vi/',
    outDir: '../../../xciii/site/dist/docs/vi',

    head: [
        ['link', {rel: 'icon', href: '/docs/vi/favicon.svg'}],
    ],

    markdown: {
        theme: {light: 'github-light', dark: 'github-dark'},
    },

    locales: {root: ru, en},

    themeConfig: {

        // No repository link and no social icons: this guide is for somebody
        // using the browser, and a source tree answers nothing asked here.

        search: {
            provider: 'local',
            options: {
                // The theme's own search strings are English already, so only
                // the root locale needs spelling out.
                translations: {
                    button: {
                        buttonText: 'Поиск',
                        buttonAriaLabel: 'Поиск по руководству',
                    },
                    modal: {
                        displayDetails: 'Показать подробности',
                        resetButtonTitle: 'Очистить',
                        backButtonTitle: 'Закрыть',
                        noResultsText: 'Ничего не нашлось',
                        footer: {
                            selectText: 'открыть',
                            navigateText: 'листать',
                            closeText: 'закрыть',
                        },
                    },
                },
                locales: {
                    en: {
                        translations: {
                            button: {
                                buttonText: 'Search',
                                buttonAriaLabel: 'Search the guide',
                            },
                            modal: {
                                displayDetails: 'Show details',
                                resetButtonTitle: 'Clear',
                                backButtonTitle: 'Close',
                                noResultsText: 'Nothing found',
                                footer: {
                                    selectText: 'open',
                                    navigateText: 'browse',
                                    closeText: 'close',
                                },
                            },
                        },
                    },
                },
            },
        },
    },
})
