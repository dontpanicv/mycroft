// Mycroft's screen, part 1: the link to the app, the stores, and hot reload.
//
// This file stays loaded while generations come and go: when a new generation changes the screen, boot.js imports
// that generation's app.js and swaps it in place. The stores below survive the swap, so nothing on screen is lost.
// Changing boot.js or index.html itself means a full page reload (the UI state is saved first). Read README.md
// before changing it.

const native = (op, args = {}) => window.webkit.messageHandlers.mycroft.postMessage({ op, args })
const root = document.getElementById('root')
const generationOf = (path) => {
	const match = path.match(/^\/g\/(\d+)\//)
	return match ? Number(match[1]) : null
}
const describe = (error) => (error && error.stack ? `${error.message}\n${error.stack}` : String(error))
const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()))

/** A tiny observable value: get(), set(patch), subscribe(fn) → unsubscribe. */
function createStore(initial) {
	let value = initial
	const listeners = new Set()
	return {
		get: () => value,
		set(patch) {
			value = { ...value, ...(typeof patch === 'function' ? patch(value) : patch) }
			for (const listener of listeners) listener(value)
		},
		subscribe(listener) {
			listeners.add(listener)
			return () => listeners.delete(listener)
		},
	}
}

// What the app tells the screen: `state` (threads, sign-in, generations, machines…), `views` (open threads by id),
// and the latest `listen` and `pairing` events. See README.md for their shapes.
const data = createStore({ state: null, views: {}, listen: null, pairing: null })

// What the screen remembers about itself: navigation, drafts… Saved in the app, so it survives hot reloads,
// full reloads and relaunches.
const ui = createStore({})
let saveTimer
ui.subscribe((value) => {
	clearTimeout(saveTimer)
	saveTimer = setTimeout(() => native('ui.save', { state: JSON.stringify(value) }), 250)
})

const listeners = new Map()
let errorsSinceMount = []
addEventListener('error', (event) => errorsSinceMount.push(event.error || event.message))
addEventListener('unhandledrejection', (event) => errorsSinceMount.push(event.reason))

const runtime = {
	/** Calls the app: `await call('thread.send', { id, text })`. Rejects with the app's error message. */
	call: native,
	data,
	ui,
	/** Raw events from the app, e.g. on('view', fn). Returns an unsubscribe function. */
	on(type, listener) {
		if (!listeners.has(type)) listeners.set(type, new Set())
		listeners.get(type).add(listener)
		return () => listeners.get(type).delete(listener)
	},
	/** The generation whose screen code is running (null in a preview of the draft). */
	generation: generationOf(location.pathname),
	/** True when the app renders this screen off-screen to check it or take a picture. */
	preview: new URLSearchParams(location.search).has('preview'),
}

window.mycroft = {
	runtime,
	receive(type, payload) {
		if (type === 'state') data.set({ state: payload })
		else if (type === 'view') {
			data.set((current) => {
				const previous = current.views[payload.thread]
				const view = { ...previous, ...payload, entries: payload.entries ?? previous?.entries ?? [] }
				return { views: { ...current.views, [payload.thread]: view } }
			})
		} else if (type === 'hot') hot(payload)
		else data.set({ [type]: payload })
		for (const listener of listeners.get(type) ?? []) listener(payload)
	},
}

let current = null // { module, generation }

/** Imports a generation's app.js and renders it into #root. Throws if it fails to render cleanly. */
async function mount(url, generation) {
	const module = await import(url)
	errorsSinceMount = []
	module.mount(root, runtime)
	await frame()
	await frame()
	if (errorsSinceMount.length) throw errorsSinceMount[0]
	current = { module, generation }
}

/** A new generation changed the screen: swap it in place. */
async function hot({ generation, changed }) {
	if (changed.includes('boot.js') || changed.includes('index.html')) {
		// boot.js can't replace itself: reload the page from the new generation; the UI state comes back with it.
		clearTimeout(saveTimer)
		await native('ui.save', { state: JSON.stringify(ui.get()) })
		location.replace(`/g/${generation}/index.html${location.search}${location.hash}`)
		return
	}
	const previous = current
	try {
		// Load (and fail on syntax errors) before touching what is on screen.
		await import(`/g/${generation}/app.js`)
		if (changed.some((file) => file.endsWith('.css'))) await swapStyles(generation)
		// Screens unmount only to come back: what lives in the app (a conversation) must not end with them.
		runtime.swapping = true
		previous?.module.unmount?.(root)
		runtime.generation = generation
		await mount(`/g/${generation}/app.js`, generation)
		native('ui.hot', { generation })
	} catch (error) {
		// Put the previous screen back, then report.
		try {
			current?.module.unmount?.(root)
			if (previous) {
				await swapStyles(previous.generation)
				runtime.generation = previous.generation
				previous.module.mount(root, runtime)
				current = previous
			}
		} catch {}
		native('ui.hot', { generation, error: describe(error) })
	} finally {
		runtime.swapping = false
	}
}

/** Points every <link data-hot> at the generation's copy, keeping the old one until the new one has loaded. */
async function swapStyles(generation) {
	await Promise.all(
		[...document.querySelectorAll('link[data-hot]')].map(
			(link) =>
				new Promise((resolve, reject) => {
					const name = link.getAttribute('href').split('/').pop()
					const next = link.cloneNode()
					next.href = `/g/${generation}/${name}`
					next.onload = () => {
						link.remove()
						resolve()
					}
					next.onerror = () => reject(new Error(`Failed to load ${next.href}`))
					link.after(next)
				}),
		),
	)
}

async function start() {
	const boot = await native('ui.boot')
	data.set({ state: boot.state })
	if (boot.uiState) {
		try {
			ui.set(JSON.parse(boot.uiState))
		} catch {}
	}
	runtime.preview = boot.preview
	await mount(new URL('app.js', location.href).pathname, runtime.generation)
	native('ui.ready', { generation: runtime.generation })
}

start().catch((error) => native('ui.failed', { generation: runtime.generation, error: describe(error) }))
