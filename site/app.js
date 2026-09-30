// Dark is the screen and the default. Which theme a visitor gets is decided by
// the inline script in index.html, before the first paint; here we only
// remember what they switch to.
const root = document.documentElement

document.getElementById('theme-toggle').addEventListener('click', () => {
    const next = root.dataset.theme === 'dark' ? 'light' : 'dark'
    root.dataset.theme = next
    localStorage.setItem('deffun-theme', next)
})
