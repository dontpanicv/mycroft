// Mycroft's screen, part 2: the app. boot.js calls mount() with the runtime, and unmount() before a newer
// generation's app.js takes over. Everything here can change in a hot reload; keep state that must survive one in
// the runtime's stores (useUI / useData), not only in component state.

import { html, render, useEffect, useRef, useState } from '/lib/preact.js'
import { Runtime, useNavigation, useData, useRuntime, Label, Spinner } from './lib.js'
import { Threads, Archived } from './screens/threads.js'
import { Thread } from './screens/thread.js'
import { Settings, Notices } from './screens/settings.js'
import { Pair } from './screens/pair.js'

/** Routes: '#/' threads, '#/t/<id>' a thread, '#/new' a new thread's draft, '#/archived', '#/settings', '#/notices', '#/pair'. */
function screenFor(route) {
	const [, name, arg] = route.match(/^#\/([^/]*)\/?(.*)$/) ?? []
	switch (name) {
		case 't': return html`<${Thread} id=${Number(arg)} />`
		case 'new': return html`<${Thread} id=${null} />`
		case 'archived': return html`<${Archived} />`
		case 'settings': return html`<${Settings} />`
		case 'notices': return html`<${Notices} />`
		case 'pair': return html`<${Pair} />`
		default: return html`<${Threads} />`
	}
}

function App() {
	const { route, depth, back } = useNavigation()
	const phase = useData((d) => d.state?.phase ?? 'starting')
	const failure = useData((d) => d.state?.failure)
	const { ui } = useRuntime()
	const swipe = useEdgeSwipe(depth > 1, back)
	const direction = ui.get().back ? 'back' : 'forward'

	if (phase === 'failed') {
		return html`<main class="screen center grid">
			<div class="card">
				<${Label} tone="danger">Mycroft could not start<//>
				<pre class="mono small muted">${failure}</pre>
			</div>
		</main>`
	}
	return html`
		<div class="stage" ...${swipe.handlers}>
			<div class=${`page ${direction}`} key=${route + depth} style=${swipe.style}>${screenFor(route)}</div>
		</div>
		${phase === 'starting' && html`<div class="waking grid"><${Spinner} /><${Label}>Waking the brain<//></div>`}
	`
}

/** Swipe from the left edge to go back, like a navigation stack. */
function useEdgeSwipe(enabled, back) {
	const [dx, setDx] = useState(0)
	const start = useRef(null)
	const handlers = {
		onTouchStart(event) {
			const touch = event.touches[0]
			start.current = enabled && touch.clientX < 24 ? { x: touch.clientX, y: touch.clientY, t: Date.now() } : null
		},
		onTouchMove(event) {
			if (!start.current) return
			const touch = event.touches[0]
			const moved = touch.clientX - start.current.x
			if (Math.abs(touch.clientY - start.current.y) > 40 && moved < 30) start.current = null
			else setDx(Math.max(0, moved))
		},
		onTouchEnd() {
			if (!start.current) return
			const fast = dx / Math.max(1, Date.now() - start.current.t) > 0.5
			start.current = null
			setDx(0)
			if (dx > innerWidth * 0.33 || (fast && dx > 40)) back()
		},
	}
	return { handlers, style: dx ? `transform: translateX(${dx}px); transition: none; box-shadow: -20px 0 40px rgba(0,0,0,.5)` : '' }
}

/** Tells the app the colours in style.css, so the native parts (Live Activity, Dynamic Island) match the screen. */
function reportTheme(runtime) {
	const css = getComputedStyle(document.documentElement)
	const read = (name) => css.getPropertyValue(name).trim()
	runtime.call('ui.theme', {
		accent: read('--accent'), accentSoft: read('--accent-soft'), canvas: read('--canvas'), raised: read('--raised'),
		ink: read('--ink'), inkMuted: read('--ink-muted'), success: read('--success'), danger: read('--danger'),
	}).catch(() => {})
}

export function mount(root, runtime) {
	render(html`<${Runtime.Provider} value=${runtime}><${App} /><//>`, root)
	if (!runtime.preview) reportTheme(runtime)
	// A preview can be asked for a route: index.html?preview=1#/settings
	if (runtime.preview && location.hash.length > 2) runtime.ui.set({ stack: ['#/', location.hash] })
}

export function unmount(root) {
	render(null, root)
}
